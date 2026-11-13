"""Tern pane road: a pairing link offered over the control channel, claimed once over a sessionless loopback GET."""
import http.client
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
import idea_tern
from idea_bridge import TERN_PAIR_URL, TernOffers
from idea_launch import OwnerService
from idea_runtime import Runtime, RuntimeError as OwnerError

RID = 'ab' * 16
CODE = '0123456789abcdef' * 2


class Clock:
    def __init__(self): self.now = 1000.0
    def __call__(self): return self.now


def link(port, binding=None, code=CODE):
    return 'http://127.0.0.1:%d/%s#pair=%s' % (port, '?binding=binding_' + binding if binding else '', code)


@unittest.skipUnless(os.name == 'posix', 'owner runtime is POSIX')
class TernClaimTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name) / 'ideas'
        self.root = Path(self.temp.name) / 'private'
        self.owner = OwnerService(Runtime(self.store, self.root).acquire_owner())
        self.owner.start()
        self.addCleanup(self.owner.shutdown)
        self.clock = Clock()
        self.owner.server.tern = TernOffers(self.clock)
        self.port = self.owner.server.server_port
        self.url = link(self.port)
        self.client = Runtime(self.store, self.root)

    def request(self, path, method='GET', host=None, headers=None):
        server = self.owner.server
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        h = {'Host': host or server.host}
        h.update(headers or {})
        try:
            conn.request(method, path, headers=h)
            response = conn.getresponse()
            return response.status, json.loads(response.read()), response
        finally:
            conn.close()

    def claim(self, rid=RID, **kw):
        status, body, response = self.request('/api/v1/tern-claim?rid=' + rid, **kw)
        return status, body

    def result(self, how, rid=RID):
        status, body, _ = self.request('/api/v1/tern-result?rid=%s&how=%s' % (rid, how))
        return status, body

    def offer(self, rid=RID, url=None):
        return self.owner.server.tern.offer(rid, self.url if url is None else url, self.port)

    def test_offer_then_claim_returns_the_link_once(self):
        self.assertTrue(self.offer())
        status, body, response = self.request('/api/v1/tern-claim?rid=' + RID)
        self.assertEqual((status, body), (200, dict(ok=True, url=self.url)))
        self.assertEqual(response.getheader('Cache-Control'), 'no-store')
        self.assertEqual(self.claim(), (404, dict(ok=False, code='tern_claim_unavailable')))

    def test_unknown_rid_404(self):
        self.assertEqual(self.claim('cd' * 16), (404, dict(ok=False, code='tern_claim_unavailable')))

    def test_expiry_at_30_seconds(self):
        self.offer()
        self.clock.now += 29.9
        self.assertEqual(self.owner.server.tern.state(RID), 'pending')
        self.clock.now += 0.1
        self.assertEqual(self.claim(), (404, dict(ok=False, code='tern_claim_unavailable')))
        self.assertEqual(self.owner.server.tern.state(RID), 'unknown')

    def test_result_rules(self):
        self.offer()
        self.assertEqual(self.result('above'), (404, dict(ok=False, code='tern_result_unavailable')))  # before a claim
        self.assertEqual(self.owner.server.tern.state(RID), 'pending')
        self.claim()
        status, body = self.result('sideways')
        self.assertEqual((status, body['code']), (400, 'invalid_query'))
        self.assertEqual(self.owner.server.tern.state(RID), 'claimed')
        self.assertEqual(self.result('above'), (200, dict(ok=True)))
        self.assertEqual(self.result('beside'), (404, dict(ok=False, code='tern_result_unavailable')))  # twice
        self.assertEqual(self.owner.server.tern.state(RID), 'above')

    def test_result_window_is_60_seconds_from_the_claim(self):
        self.offer()
        self.clock.now += 29
        self.claim()
        self.clock.now += 31
        self.assertEqual(self.result('above')[0], 200)
        self.assertEqual(self.owner.server.tern.state(RID), 'above')
        other = 'ef' * 16
        self.assertTrue(self.offer(other))
        self.clock.now += 29
        self.claim(other)
        self.clock.now += 60
        self.assertEqual(self.result('above', other)[0], 404)
        self.assertEqual(self.owner.server.tern.state(other), 'unknown')

    def test_state_transitions(self):
        for how in ('above', 'beside', 'open_failed'):
            with self.subTest(how=how):
                rid = ('%02x' % len(how)) * 16
                self.assertEqual(self.owner.server.tern.state(rid), 'unknown')
                self.assertTrue(self.offer(rid))
                self.assertEqual(self.owner.server.tern.state(rid), 'pending')
                self.claim(rid)
                self.assertEqual(self.owner.server.tern.state(rid), 'claimed')
                self.assertEqual(self.result(how, rid)[0], 200)
                self.assertEqual(self.owner.server.tern.state(rid), how)

    def test_table_refuses_bad_how_and_duplicates_directly(self):
        table = TernOffers(self.clock)
        self.assertTrue(table.offer(RID, self.url, self.port))
        self.assertFalse(table.offer(RID, self.url, self.port))
        self.assertEqual(table.claim(RID), self.url)
        for how in ('sideways', '', None, 'ABOVE', 'claimed', 'pending'):
            self.assertFalse(table.result(RID, how))
        self.assertEqual(table.state(RID), 'claimed')
        self.assertTrue(table.result(RID, 'open_failed'))

    def test_cap_of_eight_and_duplicates(self):
        for index in range(8):
            self.assertTrue(self.offer('%032x' % index))
        self.assertFalse(self.offer('%032x' % 9))
        self.assertFalse(self.offer('%032x' % 3))  # duplicate
        self.clock.now += 30
        self.assertTrue(self.offer('%032x' % 9))  # the expired are swept

    def test_bad_offers_refused(self):
        bad = (link(self.port + 1), 'http://localhost:%d/#pair=%s' % (self.port, CODE), 'http://10.0.0.1:%d/#pair=%s' % (self.port, CODE),
               'https://127.0.0.1:%d/#pair=%s' % (self.port, CODE), self.url + 'x', link(self.port, code='AB' * 16), 'x', '')
        for url in bad:
            with self.subTest(url=url):
                self.assertFalse(self.offer(url=url))
        self.assertFalse(self.owner.server.tern.offer(RID, None, self.port))
        for rid in ('AB' * 16, 'ab' * 15, 'ab' * 17, 'zz' * 16, '', None):
            with self.subTest(rid=rid):
                self.assertFalse(self.offer(rid))
        self.assertTrue(self.offer(url=link(self.port, 'ab' * 16)))

    def test_host_and_method_pins(self):
        self.offer()
        status, body = self.claim(host='127.0.0.1:1')
        self.assertEqual((status, body['code']), (403, 'wrong_host'))
        self.assertEqual(self.owner.server.tern.state(RID), 'pending')  # a refused request claimed nothing
        for path in ('/api/v1/tern-claim?rid=' + RID, '/api/v1/tern-result?rid=%s&how=above' % RID):
            status, body, _ = self.request(path, method='POST', headers={'Origin': self.owner.server.origin, 'Content-Type': 'application/json'})
            self.assertEqual(status, 405)
        self.assertEqual(self.owner.server.tern.state(RID), 'pending')

    def test_bad_queries(self):
        for query in ('', '?rid=', '?rid=' + 'AB' * 16, '?rid=' + 'ab' * 15, '?rid=' + RID + '&rid=' + RID, '?rid=' + RID + '&x=1', '?x=' + RID):
            with self.subTest(query=query):
                status, body, _ = self.request('/api/v1/tern-claim' + query)
                self.assertEqual((status, body['code']), (400, 'invalid_query'))
        for query in ('?rid=' + RID, '?rid=%s&how=above&x=1' % RID, '?rid=%s&how=above&how=above' % RID, '?how=above', '?rid=%s&other=above' % RID):
            with self.subTest(query=query):
                status, body, _ = self.request('/api/v1/tern-result' + query)
                self.assertEqual((status, body['code']), (400, 'invalid_query'))

    def test_claim_does_not_touch_the_idle_clock(self):
        runtime = self.owner.runtime
        self.offer()
        before = runtime._last_activity
        import time
        time.sleep(.02)
        self.claim()
        self.result('above')
        self.claim()
        self.assertEqual(runtime._last_activity, before)

    def test_link_is_in_no_file(self):
        self.owner.server.tern = TernOffers()  # the real clock
        self.client.tern_offer(RID, self.url, timeout=5)
        self.assertEqual(self.claim()[1]['url'], self.url)
        hits = []
        for path in Path(self.temp.name).rglob('*'):
            if path.is_file() and CODE.encode() in path.read_bytes():
                hits.append(str(path))
        self.assertEqual(hits, [])

    def test_control_round_trip(self):
        self.owner.server.tern = TernOffers()
        self.assertEqual(self.client.tern_state(RID, timeout=5), 'unknown')
        self.assertIsNone(self.client.tern_offer(RID, self.url, timeout=5))
        self.assertEqual(self.client.tern_state(RID, timeout=5), 'pending')
        self.assertEqual(self.claim()[1]['url'], self.url)
        self.assertEqual(self.client.tern_state(RID, timeout=5), 'claimed')
        self.assertEqual(self.result('beside')[0], 200)
        self.assertEqual(self.client.tern_state(RID, timeout=5), 'beside')

    def test_control_refusals_are_typed(self):
        self.owner.server.tern = TernOffers()
        self.client.tern_offer(RID, self.url, timeout=5)
        for rid, url in ((RID, self.url), ('cd' * 16, link(self.port + 1)), ('cd' * 16, 'x')):
            with self.subTest(rid=rid, url=url):
                with self.assertRaises(OwnerError) as caught:
                    self.client.tern_offer(rid, url, timeout=5)
                self.assertEqual(caught.exception.code, 'tern_offer_refused')
        for call in (lambda: self.client.tern_offer('bad', self.url), lambda: self.client.tern_offer(RID, 5),
                     lambda: self.client.tern_state('bad'), lambda: self.client.tern_state(None)):
            with self.assertRaises(OwnerError) as caught:
                call()
            self.assertEqual(caught.exception.code, 'invalid_control')

    def test_control_needs_the_owner_mac(self):
        server = self.owner.server
        for operation, body in (('tern-offer', dict(rid=RID, url=self.url)), ('tern-state', dict(rid=RID))):
            payload = dict(challenge='1' * 64, instance_nonce='2' * 64, store_sha256='3' * 64, **body)
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            try:
                conn.request('POST', '/control/v1/' + operation, json.dumps(payload),
                             {'Host': server.host, 'Content-Type': 'application/json', 'Authorization': 'Idea-HMAC ' + '0' * 64})
                response = conn.getresponse()
                self.assertEqual(response.status, 401)
                self.assertNotIn(self.url.encode(), response.read())
            finally:
                conn.close()
        self.assertEqual(server.tern.state(RID), 'unknown')

    def test_grammar_agrees_with_the_tern_module(self):
        cases = ['http://127.0.0.1:%s/%s#pair=%s' % (port, binding, code)
                 for port in ('1', '80', '9999', '10000', '49152', '65535', '65536', '99999', '0', '01', '', '-1', '1e3', '٣')
                 for binding in ('', '?binding=binding_' + 'a' * 32, '?binding=binding_' + 'A' * 32, '?binding=binding_' + 'a' * 31, '?binding=', '?x=1')
                 for code in (CODE, 'f' * 31, 'f' * 33, 'F' * 32, '')]
        cases += ['http://localhost:80/#pair=' + CODE, 'https://127.0.0.1:80/#pair=' + CODE, 'http://127.0.0.1:80#pair=' + CODE,
                  'http://127.0.0.1:80/#pair=' + CODE + '\n', ' http://127.0.0.1:80/#pair=' + CODE, 'http://127.0.0.1:80/#pair=' + CODE + 'x',
                  'http://127.0.0.1:80//#pair=' + CODE, 'http://127.0.0.1.:80/#pair=' + CODE]
        accepted = 0
        for case in cases:
            with self.subTest(case=case):
                ours = re.fullmatch(TERN_PAIR_URL, case) is not None
                self.assertEqual(ours, idea_tern.URL_SHAPE.fullmatch(case) is not None)
                accepted += ours
        self.assertGreater(accepted, 10)
        self.assertLess(accepted, len(cases))


if __name__ == '__main__':
    unittest.main()
