"""Fixed browser port: bridge binding, launch pre-checks and the cold-start twin (job A cells)."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
import idea_launch as launch
from idea_bridge import BridgeError, BridgeServer
from idea_domain import IdeaError
from idea_runtime import Runtime, RuntimeError as OwnerError


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


def get(port, host):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        conn.request('GET', '/api/v1/ideas', headers={'Host': host})
        response = conn.getresponse()
        raw = response.read()
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        return response.status, body
    finally:
        conn.close()


def port_of(opened):
    return int(opened['origin'].rstrip('/').rsplit(':', 1)[1])


@unittest.skipUnless(os.name == 'posix', 'fixed-port rebind semantics are POSIX')
class FixedPortTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name) / 'ideas'
        self.root = Path(self.temp.name) / 'private'
        self.port = free_port()

    def listener(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(sock.close)
        sock.bind(('127.0.0.1', self.port))
        sock.listen(1)
        return sock

    def serving(self, **kwargs):
        server = BridgeServer(**kwargs)
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
        thread.start()

        def stop():
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.addCleanup(stop)
        return server

    # 1
    def test_configured_port_origin_host_and_host_header_enforced(self):
        server = self.serving(port=self.port)
        self.assertEqual(server.server_port, self.port)
        self.assertEqual(server.origin, 'http://127.0.0.1:%d' % self.port)
        self.assertEqual(server.host, '127.0.0.1:%d' % self.port)
        self.assertIs(BridgeServer.allow_reuse_port, False)
        self.assertIs(server.allow_reuse_port, False)
        _, body = get(self.port, '127.0.0.1:%d' % self.port)
        self.assertNotEqual(body.get('code'), 'wrong_host')
        other = free_port()
        status, body = get(self.port, '127.0.0.1:%d' % other)
        self.assertEqual((status, body.get('code')), (403, 'wrong_host'))

    # 2
    def test_quick_restart_after_server_closed_connection_binds(self):
        server = BridgeServer(port=self.port)
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
        thread.start()
        get(self.port, '127.0.0.1:%d' % self.port)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        again = BridgeServer(port=self.port)
        self.addCleanup(again.server_close)
        self.assertEqual(again.server_port, self.port)

    # 3
    def test_port_held_by_plain_listener_is_port_in_use(self):
        self.listener()
        with self.assertRaises(BridgeError) as caught:
            BridgeServer(port=self.port)
        self.assertEqual(caught.exception.code, 'port_in_use')
        with self.assertRaises(launch.LaunchError) as caught:
            launch._check_port_free(self.port)
        self.assertEqual(caught.exception.code, 'port_in_use')
        self.assertEqual(caught.exception.details['port'], self.port)

    def stub_time(self):
        now = [0.0]
        return (lambda: now[0]), (lambda seconds: now.__setitem__(0, now[0] + max(seconds, .01)))

    # 4
    def test_ensure_service_refuses_held_port_before_spawn_at_the_deadline(self):
        self.listener()
        clock, sleep = self.stub_time()
        probes = []

        def unavailable(self, timeout=1):
            probes.append(timeout)
            raise OwnerError('owner_unavailable')

        def spawn(*a, **k):
            self.fail('spawn must not run when the port is held')
        with patch.object(Runtime, 'probe_owner', unavailable):
            with self.assertRaises(launch.LaunchError) as caught:
                launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn,
                                      clock=clock, sleep=sleep)
        self.assertFalse(Runtime(self.store, self.root).owner_lock_held())  # no owner holds the lock: the port is foreign
        self.assertGreaterEqual(clock(), 5)  # refused at the readiness deadline, not on the first miss
        self.assertEqual(caught.exception.code, 'port_in_use')
        self.assertEqual(caught.exception.details['port'], self.port)
        self.assertGreater(len(probes), 5)  # it kept probing until the deadline, not raised on the first miss

    # 4b
    def test_port_held_by_starting_owner_holding_its_lock_is_readiness_timeout_not_port_in_use(self):
        self.listener()  # the starting owner has bound the port but not published discovery
        owner = Runtime(self.store, self.root)
        owner.acquire_owner()  # and holds the store's service lock the way a real owner does
        self.addCleanup(owner.close)
        clock, sleep = self.stub_time()

        def unavailable(self, timeout=1):
            raise OwnerError('owner_unavailable')

        def spawn(*a, **k):
            self.fail('spawn must not run when the port is held')
        with patch.object(Runtime, 'probe_owner', unavailable):
            with self.assertRaises(launch.LaunchError) as caught:
                launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn,
                                      clock=clock, sleep=sleep)
        self.assertEqual(caught.exception.code, 'service_readiness_timeout')
        self.assertGreaterEqual(clock(), 5)
        self.assertTrue(Runtime(self.store, self.root).owner_lock_held())

    # 5
    def test_live_owner_on_port_is_reused_without_refusal_or_spawn(self):
        self.listener()  # the owner's own listener holds the port
        expected = dict(origin='http://127.0.0.1:%d' % self.port)

        def probe(self, timeout=1):
            return expected

        def spawn(*a, **k):
            self.fail('a live owner must not be respawned')
        with patch.object(Runtime, 'probe_owner', probe):
            result = launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn)
        self.assertEqual(result, expected)

    # 6
    def test_child_losing_bind_race_reports_port_in_use_at_the_deadline_without_respawn(self):
        def unavailable(self, timeout=1):
            raise OwnerError('owner_unavailable')
        calls = []
        clock, sleep = self.stub_time()

        def spawn(*a, **k):
            calls.append(a)
            self.listener()  # another process wins the port after the pre-check
            return SimpleNamespace(poll=lambda: 1)
        with patch.object(Runtime, 'probe_owner', unavailable):
            with self.assertRaises(launch.LaunchError) as caught:
                launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn,
                                      clock=clock, sleep=sleep)
        self.assertEqual(len(calls), 1)
        self.assertFalse(Runtime(self.store, self.root).owner_lock_held())
        self.assertGreaterEqual(clock(), 5)  # the stub clock reached the readiness deadline before the refusal
        self.assertEqual(caught.exception.code, 'port_in_use')
        self.assertEqual(caught.exception.details['port'], self.port)

    # 6a2
    def test_foreign_listener_appearing_while_our_child_lives_without_owning_is_port_in_use(self):
        # The port was free at the pre-check, our child stays alive but never takes ownership, and another
        # process binds the port meanwhile: the deadline must look again, not trust the loop's earlier view.
        def unavailable(self, timeout=1):
            raise OwnerError('owner_unavailable')
        clock, sleep = self.stub_time()

        def spawn(*a, **k):
            self.listener()
            return SimpleNamespace(poll=lambda: None)
        with patch.object(Runtime, 'probe_owner', unavailable):
            with self.assertRaises(launch.LaunchError) as caught:
                launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn,
                                      clock=clock, sleep=sleep)
        self.assertGreaterEqual(clock(), 5)
        self.assertEqual(caught.exception.code, 'port_in_use')
        self.assertEqual(caught.exception.details['port'], self.port)

    # 6b
    def test_concurrent_start_owner_answering_later_is_returned_not_refused(self):
        self.listener()  # owner A has bound the port but not yet published discovery
        expected = dict(origin='http://127.0.0.1:%d/' % self.port, identity={})
        clock, sleep = self.stub_time()
        calls = []

        def probe(self, timeout=1):
            calls.append(1)
            if len(calls) <= 4:
                raise OwnerError('owner_unavailable')
            return expected

        def spawn(*a, **k):
            self.fail('a starting owner must not be respawned')
        with patch.object(Runtime, 'probe_owner', probe):
            result = launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn,
                                           clock=clock, sleep=sleep)
        self.assertIs(result, expected)
        self.assertEqual(len(calls), 5)

    # 6b2
    def test_child_exit_while_other_owner_starts_is_not_refused(self):
        expected = dict(origin='http://127.0.0.1:%d/' % self.port, identity={})
        clock, sleep = self.stub_time()
        calls, spawns = [], []

        def probe(self, timeout=1):
            calls.append(1)
            if len(calls) <= 5:
                raise OwnerError('owner_unavailable')
            return expected

        def spawn(*a, **k):
            spawns.append(a)
            self.listener()  # owner A, launched by a concurrent launcher, wins the port and is still starting
            return SimpleNamespace(poll=lambda: 1)
        with patch.object(Runtime, 'probe_owner', probe):
            result = launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn,
                                           clock=clock, sleep=sleep)
        self.assertIs(result, expected)
        self.assertEqual(len(spawns), 1)

    # 6c
    def test_running_service_on_another_port_is_port_mismatch(self):
        other = free_port()
        for origin in ('http://127.0.0.1:%d/' % other, 'http://127.0.0.1/', 'http://127.0.0.1:x/', None, 5):
            def probe(self, timeout=1, origin=origin):
                return dict(identity={}, origin=origin)

            def spawn(*a, **k):
                self.fail('no spawn on mismatch')
            with patch.object(Runtime, 'probe_owner', probe):
                with self.assertRaises(launch.LaunchError, msg=repr(origin)) as caught:
                    launch.ensure_service(self.store, self.root, dict(browser_port=self.port), spawn=spawn)
            self.assertEqual(caught.exception.code, 'port_mismatch')
            self.assertEqual(caught.exception.details['port'], self.port)
        good = dict(identity={}, origin='http://127.0.0.1:%d/' % self.port)
        with patch.object(Runtime, 'probe_owner', lambda self, timeout=1: good):
            self.assertIs(launch.ensure_service(self.store, self.root, dict(browser_port=self.port)), good)
        # no browser_port configured: any running service is reused as before
        with patch.object(Runtime, 'probe_owner', lambda self, timeout=1: dict(origin='http://127.0.0.1:%d/' % other)):
            self.assertIsNotNone(launch.ensure_service(self.store, self.root, {}))

    # 6d
    def test_cli_envelope_carries_port_for_port_mismatch(self):
        import idea
        failure = launch.LaunchError('port_mismatch', port=self.port, owner_token='SECRET')
        args = SimpleNamespace(command='session-open', readiness_timeout=1, resume=None, idea_id=None,
                               runtime_root_fallback=None)
        with patch.object(idea, 'launcher_configuration', return_value=(self.store, self.root, {}, None)), \
                patch.object(launch, 'open_session', side_effect=failure):
            result = idea.run_launcher(args)
        self.assertEqual(result, dict(ok=False, error={'code': 'port_mismatch', 'message': 'port_mismatch'}, port=self.port))

    # 7
    def test_unset_port_encodes_as_before_and_binds_randomly(self):
        base = {'store_path', 'plan_validator_argv', 'validator_timeout_seconds'}
        for config in (None, {}, {'validator_timeout_seconds': 10}):
            result = launch._config(config, self.store)
            self.assertNotIn('browser_port', result)
            self.assertEqual(set(result), base)
        self.assertEqual(launch._config(None, self.store)['validator_timeout_seconds'], 30)
        workspace = Path(self.temp.name) / 'ws'
        workspace.mkdir()
        result = launch._config({'default_workspace': {'name': 'ws', 'path': str(workspace)}}, self.store)
        self.assertEqual(set(result), base | {'default_workspace'})
        self.assertEqual(launch._config({'browser_port': self.port}, self.store)['browser_port'], self.port)
        server = BridgeServer()
        self.addCleanup(server.server_close)
        self.assertGreaterEqual(server.server_port, 1024)
        self.assertIs(server.allow_reuse_address, False)

    # 8
    def test_bad_port_values_are_refused(self):
        for bad in (True, 0, 80, 1023, 65536, '8840', 8840.0):
            with self.assertRaises(IdeaError, msg=repr(bad)) as caught:
                launch._config({'browser_port': bad}, self.store)
            self.assertEqual(caught.exception.code, 'invalid_config', repr(bad))
        for bad in (True, 80, 65536, 1023, '8840', 8840.0):
            with self.assertRaises(ValueError, msg=repr(bad)):
                BridgeServer(port=bad)

    # 9
    def test_cli_detail_whitelist_for_port(self):
        import idea
        self.assertEqual(idea._safe_launch_details({'port': self.port}), {'port': self.port})
        for bad in (True, 0, 70000, '1', 1.0):
            self.assertNotIn('port', idea._safe_launch_details({'port': bad}), repr(bad))

    # 10
    def test_cold_start_twin_same_port_across_real_owner_restart(self):
        config = dict(browser_port=self.port)
        children = []
        client = Runtime(self.store, self.root)

        def spawn(*a, **k):
            child = subprocess.Popen(*a, **k)
            children.append(child)
            return child

        def cleanup():
            end = time.monotonic() + 8
            while any(c.poll() is None for c in children) and time.monotonic() < end:
                try:
                    client.request_owned_stop(timeout=3)
                except Exception:
                    time.sleep(.05)
            for c in children:
                c.wait(timeout=5)
        self.addCleanup(cleanup)
        first = launch.ensure_service(self.store, self.root, config, spawn=spawn)
        self.assertEqual(port_of(first), self.port)
        client.request_owned_stop(timeout=2)
        children[-1].wait(timeout=4)
        with self.assertRaises(OwnerError):
            client.probe_owner()
        second = launch.ensure_service(self.store, self.root, config, spawn=spawn)
        self.assertEqual(len(children), 2)
        self.assertEqual(port_of(second), self.port)
        self.assertNotEqual(first['identity']['instance_nonce'], second['identity']['instance_nonce'])


if __name__ == '__main__':
    unittest.main()
