"""An events wait whose answer is held up by a page request must not read as agent_unavailable.

Live, 7 Nov 2026: `events --timeout 25` returned agent_unavailable a few seconds after a fill,
while the broker still said connected. The service answers an events wait only after it has
re-taken the binding lock (BODY_DEADLINE), and a page request (the fill's draft save, the state
read after it) may hold that lock for seconds. Real owned service, real native client.
"""
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from idea_agent_client import AgentClientError
import test_agent_launch as rig  # real owner + browser + native client; module import so its tests are not collected here


@unittest.skipUnless(os.name == 'posix', 'Native owner ACLs remain unqualified')
class AgentWaitDeadlineTests(unittest.TestCase):
    setUp = rig.AgentLaunchTests.setUp
    start_owner = rig.AgentLaunchTests.start_owner
    cleanup = rig.AgentLaunchTests.cleanup
    wire = rig.AgentLaunchTests.wire
    pair = rig.AgentLaunchTests.pair
    browser = rig.AgentLaunchTests.browser

    def binding(self):
        policy = self.owner.policy
        with policy._registry:
            return policy._entries[self.opened['binding_id']].binding

    def hold_lock(self, start, release):
        """From another thread, take the binding lock at `start` s and keep it until `release` s."""
        lock, taken = self.binding().lock, threading.Event()
        t0 = time.monotonic()
        def run():
            time.sleep(max(0, start - (time.monotonic() - t0)))
            with lock:
                taken.set()
                time.sleep(max(0, release - (time.monotonic() - t0)))
        thread = threading.Thread(target=run, daemon=True); thread.start()
        self.addCleanup(thread.join, 10)
        return taken

    def status(self):
        # Broker condition only: never the binding lock the test is holding.
        return self.owner.broker.status(self.opened['binding_id'], self.generation)['agent_status']

    def test_a_page_request_holding_the_lock_past_the_wait_does_not_read_as_unavailable(self):
        self.generation = self.owner.policy.agent_credentials(self.opened['binding_id'])['generation']
        self.agent.events(timeout=0)  # the agent is connected and has read the empty queue
        # The wait ends at 1 s; a page request holds the lock from 0.5 s to 3.5 s, past the client's
        # old timeout + 2 s but well inside the service's own BODY_DEADLINE for the lock.
        taken = self.hold_lock(0.5, 3.5)
        started = time.monotonic()
        try:
            result = self.agent.events(timeout=1)
        except AgentClientError as exc:
            self.fail(f'events returned {exc.code} after {time.monotonic() - started:.2f} s '
                      f'while the agent is {self.status()}')
        self.assertTrue(taken.is_set())
        self.assertEqual((result['agent_status'], result['events']), ('connected', []))
        self.assertGreaterEqual(time.monotonic() - started, 3.0)  # the answer really waited for the lock
        self.assertEqual(self.status(), 'connected')

    def test_an_answer_later_than_the_client_deadline_is_named_late_not_unavailable(self):
        # A loop stops on agent_unavailable (the service's refusal); a late answer must say what it is.
        self.generation = self.owner.policy.agent_credentials(self.opened['binding_id'])['generation']
        self.agent.events(timeout=0)
        self.hold_lock(0.5, 3.5)
        with patch('idea_agent_client.BODY_DEADLINE', 0):  # client deadline: the 1 s wait + the 2 s margin
            with self.assertRaises(AgentClientError) as caught:
                self.agent.events(timeout=1)
        self.assertEqual(caught.exception.code, 'agent_transport_timeout')
        self.assertEqual(self.status(), 'connected')


if __name__ == '__main__':
    unittest.main()
