"""SKILLS-160: the deferred claim. A candidate pane that is not focused asks with defer=1; the service hands it the link
only when no direct claim arrived within the wait. At most TERN_MAX_DEFERRED claims wait at once.
"""
import http.client
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
import idea_bridge
from idea_bridge import TernOffers
from idea_launch import OwnerService
from idea_runtime import Runtime

RID, RID2 = 'ab' * 16, 'cd' * 16
CODE = '0123456789abcdef' * 2


def link(port):
    return 'http://127.0.0.1:%d/#pair=%s' % (port, CODE)


class Clock:
    def __init__(self): self.now = 1000.0
    def __call__(self): return self.now


class FakeWait:
    """Condition wait on the fake clock: nobody notifies, so the full timeout passes."""
    def __init__(self, clock): self.clock, self.calls = clock, []
    def __call__(self, condition, timeout):
        self.calls.append(timeout); self.clock.now += timeout
        return False


class DeferredGridTests(unittest.TestCase):
    """status x operation on the table itself, fake clock."""
    def setUp(self):
        self.clock = Clock(); self.wait = FakeWait(self.clock)
        self.table = TernOffers(self.clock, wait=self.wait)
        self.port = 8845
        self.assertTrue(self.table.offer(RID, link(self.port), self.port))

    def test_constants(self):
        self.assertEqual((idea_bridge.TERN_DEFER_WAIT, idea_bridge.TERN_MAX_DEFERRED), (1.5, 2))

    def test_pending_direct_claims_at_once(self):
        self.assertEqual(self.table.claim(RID), link(self.port))
        self.assertEqual(self.wait.calls, [])

    def test_pending_deferred_claims_after_the_wait(self):
        self.assertEqual(self.table.claim(RID, deferred=True), link(self.port))
        self.assertAlmostEqual(sum(self.wait.calls), 1.5)
        self.assertEqual(self.table.state(RID), 'claimed')

    def test_pending_result_refused(self):
        self.assertFalse(self.table.result(RID, 'beside'))

    def test_claimed_refuses_both_claims_and_a_deferred_one_never_waits(self):
        self.table.claim(RID)
        self.assertIsNone(self.table.claim(RID))
        self.assertIsNone(self.table.claim(RID, deferred=True))
        self.assertEqual(self.wait.calls, [])
        self.assertTrue(self.table.result(RID, 'beside'))

    def test_final_refuses_everything(self):
        self.table.claim(RID, deferred=True); self.table.result(RID, 'beside')
        for deferred in (False, True):
            self.assertIsNone(self.table.claim(RID, deferred=deferred))
        self.assertFalse(self.table.result(RID, 'above'))
        self.assertEqual(self.table.state(RID), 'beside')

    def test_unknown_rid_deferred_is_none_at_once(self):
        """Cold start: a fresh table, no offer."""
        fresh = TernOffers(self.clock, wait=self.wait)
        self.assertIsNone(fresh.claim(RID, deferred=True))
        self.assertEqual(self.wait.calls, [])

    def test_an_offer_that_expires_during_the_wait_is_not_handed_out(self):
        self.clock.now += 29.0
        self.assertIsNone(self.table.claim(RID, deferred=True))
        self.assertEqual(self.table.state(RID), 'unknown')

    def test_after_an_expired_offer_a_new_one_works(self):
        self.clock.now += 31.0
        self.assertEqual(self.table.state(RID), 'unknown')
        self.assertTrue(self.table.offer(RID2, link(self.port), self.port))
        self.assertEqual(self.table.claim(RID2, deferred=True), link(self.port))

    def test_the_waiter_count_is_released(self):
        for _ in range(4):
            rid = os.urandom(16).hex()
            self.assertTrue(self.table.offer(rid, link(self.port), self.port))
            self.assertEqual(self.table.claim(rid, deferred=True), link(self.port))
        self.assertEqual(self.table._waiting, 0)

    def test_a_raising_wait_releases_the_count(self):
        def boom(condition, timeout): raise OSError('x')
        table = TernOffers(self.clock, wait=boom)
        table.offer(RID, link(self.port), self.port)
        with self.assertRaises(OSError):
            table.claim(RID, deferred=True)
        self.assertEqual(table._waiting, 0)


class DeferredThreadTests(unittest.TestCase):
    """Real clock and real condition, short wait."""
    WAIT = 0.6

    def setUp(self):
        self.table = TernOffers()
        self.port = 8845
        self.table.offer(RID, link(self.port), self.port)

    def deferred(self, out, rid=RID):
        start = time.monotonic()
        out.append((self.table.claim(rid, deferred=True, wait=self.WAIT), time.monotonic() - start))

    def test_a_direct_claim_during_the_wait_wins_and_wakes_the_waiter(self):
        out = []
        thread = threading.Thread(target=self.deferred, args=(out,)); thread.start()
        time.sleep(0.1)
        self.assertEqual(self.table.claim(RID), link(self.port))
        thread.join(5)
        url, took = out[0]
        self.assertIsNone(url)
        self.assertLess(took, self.WAIT - 0.2)    # woken by the claim, not by the timeout

    def test_two_deferred_claimers_one_link(self):
        out = []
        threads = [threading.Thread(target=self.deferred, args=(out,)) for _ in range(2)]
        for t in threads: t.start()
        for t in threads: t.join(5)
        self.assertEqual(sorted(url is None for url, _ in out), [False, True])

    def test_a_third_waiter_is_refused_at_once(self):
        out = []
        rids = [RID, RID2, 'ef' * 16]
        for rid in rids[1:]: self.table.offer(rid, link(self.port), self.port)
        threads = [threading.Thread(target=self.deferred, args=(out, rid)) for rid in rids[:2]]
        for t in threads: t.start()
        time.sleep(0.15)
        third = []
        self.deferred(third, rids[2])
        for t in threads: t.join(5)
        self.assertIsNone(third[0][0])
        self.assertLess(third[0][1], 0.1)
        self.assertEqual(self.table.state(rids[2]), 'pending')
        self.assertEqual([url is not None for url, _ in out], [True, True])


@unittest.skipUnless(os.name == 'posix', 'owner runtime is POSIX')
class DeferredRouteTests(unittest.TestCase):
    """Through the real owner service and HTTP route."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name) / 'ideas'; self.root = Path(self.temp.name) / 'private'
        self.owner = OwnerService(Runtime(self.store, self.root).acquire_owner())
        self.owner.start(); self.addCleanup(self.owner.shutdown)
        self.owner.server.tern = TernOffers()
        self.port = self.owner.server.server_port
        self.client = Runtime(self.store, self.root)
        patcher = patch.object(idea_bridge, 'TERN_DEFER_WAIT', 0.5); patcher.start(); self.addCleanup(patcher.stop)

    def request(self, path):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            conn.request('GET', path, headers={'Host': self.owner.server.host})
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def offer(self, rid=RID):
        return self.owner.server.tern.offer(rid, link(self.port), self.port)

    def test_deferred_claim_through_the_route(self):
        self.assertTrue(self.offer())
        start = time.monotonic()
        status, body = self.request('/api/v1/tern-claim?rid=%s&defer=1' % RID)
        self.assertEqual((status, body), (200, dict(ok=True, url=link(self.port))))
        self.assertGreaterEqual(time.monotonic() - start, 0.45)
        self.assertEqual(self.request('/api/v1/tern-result?rid=%s&how=beside' % RID)[0], 200)
        self.assertEqual(self.client.tern_state(RID), 'beside')

    def test_cold_start_deferred_is_404_at_once(self):
        start = time.monotonic()
        status, body = self.request('/api/v1/tern-claim?rid=%s&defer=1' % RID)
        self.assertEqual((status, body['code']), (404, 'tern_claim_unavailable'))
        self.assertLess(time.monotonic() - start, 0.3)

    def test_direct_claim_during_a_deferred_wait_through_the_route(self):
        self.assertTrue(self.offer())
        out = []
        thread = threading.Thread(target=lambda: out.append(self.request('/api/v1/tern-claim?rid=%s&defer=1' % RID)))
        thread.start(); time.sleep(0.1)
        self.assertEqual(self.request('/api/v1/tern-claim?rid=' + RID)[0], 200)
        thread.join(5)
        self.assertEqual((out[0][0], out[0][1]['code']), (404, 'tern_claim_unavailable'))

    def test_bad_defer_queries(self):
        self.assertTrue(self.offer())
        for query in ('&defer=0', '&defer=', '&defer=true', '&defer=1&defer=1', '&defer=1&x=1', '&Defer=1'):
            with self.subTest(query=query):
                status, body = self.request('/api/v1/tern-claim?rid=' + RID + query)
                self.assertEqual((status, body['code']), (400, 'invalid_query'))
        status, body = self.request('/api/v1/tern-result?rid=%s&defer=1' % RID)
        self.assertEqual((status, body['code']), (400, 'invalid_query'))
        self.assertEqual(self.client.tern_state(RID), 'pending')

    def test_eight_deferred_claimers_two_wait_the_poll_never_fails(self):
        self.assertTrue(self.offer())
        out, lock = [], threading.Lock()
        def ask():
            start = time.monotonic()
            status, body = self.request('/api/v1/tern-claim?rid=%s&defer=1' % RID)
            with lock: out.append((status, time.monotonic() - start))
        threads = [threading.Thread(target=ask) for _ in range(8)]
        for t in threads: t.start()
        time.sleep(0.15)
        states = [self.client.tern_state(RID) for _ in range(3)]    # the helper's state poll, during the waits
        for t in threads: t.join(5)
        self.assertEqual(states, ['pending'] * 3)
        quick = [s for s, took in out if took < 0.3]
        slow = [s for s, took in out if took >= 0.3]
        self.assertEqual(sorted(quick), [404] * 6)
        self.assertEqual(sorted(slow), [200, 404])
        self.assertEqual(self.client.tern_state(RID), 'claimed')

    def test_link_never_logged_or_filed(self):
        self.assertTrue(self.offer())
        self.request('/api/v1/tern-claim?rid=%s&defer=1' % RID)
        for path in Path(self.temp.name).rglob('*'):
            if path.is_file() and not path.is_symlink():
                try: data = path.read_bytes()
                except OSError: continue
                self.assertNotIn(CODE.encode(), data, str(path))


if __name__ == '__main__':
    unittest.main()
