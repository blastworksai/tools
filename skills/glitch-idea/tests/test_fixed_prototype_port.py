"""Fixed prototype port: bind, collision code, ready line, restart, class flags, bad ports, run-time pairing."""
import http.client
import io
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
import idea
import idea_prototype as proto
from idea_domain import IdeaError

SESSION = 'session_' + '0' * 32


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='fixport-')).resolve()
        os.chmod(self.tmp, 0o700)
        self.runtime = self.tmp / 'runtime'
        self.root = self.runtime / 'prototypes' / 'idea_x'
        self.root.mkdir(parents=True)
        for p in (self.runtime, self.runtime / 'prototypes', self.root):
            os.chmod(p, 0o700)
        (self.root / 'index.html').write_text('hi')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def serve_thread(self, server):
        t = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
        t.start()
        return t

    def run_serve(self, **kw):
        out = io.StringIO()
        state = {'live': True}

        def target():
            proto.serve_prototype(SESSION, str(self.root), 'store', self.runtime,
                                  alive=lambda: state['live'], out=out, poll=.05, **kw)
        t = threading.Thread(target=target, daemon=True)
        t.start()

        def stop():
            state['live'] = False
            t.join(5)
        self.addCleanup(stop)
        for _ in range(100):
            if out.getvalue():
                break
            threading.Event().wait(.05)
        return json.loads(out.getvalue().splitlines()[0]), stop


class BindTests(Base):
    def test_fixed_port_binds(self):
        port = free_port()
        server = proto.PrototypeServer(self.root, port=port)
        self.addCleanup(server.server_close)
        self.assertEqual(server.server_address[1], port)
        self.assertEqual(server.server_address[0], '127.0.0.1')

    def test_port_zero_picks_a_free_port(self):
        server = proto.PrototypeServer(self.root)
        self.addCleanup(server.server_close)
        self.assertGreaterEqual(server.server_address[1], 1024)

    def test_held_port_is_prototype_port_in_use(self):
        held = socket.socket()
        self.addCleanup(held.close)
        held.bind(('127.0.0.1', 0))
        held.listen(1)
        with self.assertRaises(IdeaError) as ctx:
            proto.PrototypeServer(self.root, port=held.getsockname()[1])
        self.assertEqual(ctx.exception.code, 'prototype_port_in_use')

    def test_held_port_through_serve_prototype_is_the_same_failure(self):
        held = socket.socket()
        self.addCleanup(held.close)
        held.bind(('127.0.0.1', 0))
        held.listen(1)
        with self.assertRaises(IdeaError) as ctx:
            proto.serve_prototype(SESSION, str(self.root), 'store', self.runtime,
                                  alive=lambda: True, out=io.StringIO(), port=held.getsockname()[1])
        self.assertEqual(ctx.exception.code, 'prototype_port_in_use')

    def test_second_server_on_a_live_fixed_port_is_refused(self):
        port = free_port()
        first = proto.PrototypeServer(self.root, port=port)
        self.addCleanup(first.server_close)
        with self.assertRaises(IdeaError) as ctx:
            proto.PrototypeServer(self.root, port=port)
        self.assertEqual(ctx.exception.code, 'prototype_port_in_use')

    def test_quick_restart_after_a_real_request_binds(self):
        port = free_port()
        server = proto.PrototypeServer(self.root, port=port)
        thread = self.serve_thread(server)
        conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        conn.request('GET', '/%s/index.html' % server.key, headers={'Connection': 'close'})
        self.assertEqual(conn.getresponse().read(), b'hi')
        conn.close()
        server.shutdown()
        thread.join(5)
        server.server_close()
        again = proto.PrototypeServer(self.root, port=port)
        self.addCleanup(again.server_close)
        self.assertEqual(again.server_address[1], port)

    def test_rebind_while_server_closed_first_connection_lingers(self):
        # The client holds its end open, so the server is the side that closes first and its port is left
        # lingering (FIN_WAIT/TIME_WAIT); only SO_REUSEADDR lets the same fixed port bind again.
        port = free_port()
        server = proto.PrototypeServer(self.root, port=port)
        thread = self.serve_thread(server)
        client = socket.create_connection(('127.0.0.1', port), timeout=5)
        self.addCleanup(client.close)
        client.sendall(('GET /%s/index.html HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n' % (server.key, port)).encode())
        buf = b''
        while not buf.endswith(b'hi'):
            buf += client.recv(4096)
        threading.Event().wait(.3)
        server.shutdown()
        thread.join(5)
        server.server_close()
        again = proto.PrototypeServer(self.root, port=port)
        self.addCleanup(again.server_close)
        self.assertEqual(again.server_address[1], port)


class FlagTests(Base):
    def test_reuse_port_is_false(self):
        self.assertIs(proto.PrototypeServer.allow_reuse_port, False)
        server = proto.PrototypeServer(self.root, port=free_port())
        self.addCleanup(server.server_close)
        self.assertIs(server.allow_reuse_port, False)

    def test_port_zero_keeps_reuse_address_false(self):
        self.assertIs(proto.PrototypeServer.allow_reuse_address, False)
        server = proto.PrototypeServer(self.root)
        self.addCleanup(server.server_close)
        self.assertIs(server.allow_reuse_address, False)

    def test_fixed_port_never_changes_the_class_default(self):
        server = proto.PrototypeServer(self.root, port=free_port())
        self.addCleanup(server.server_close)
        self.assertIs(proto.PrototypeServer.allow_reuse_address, False)


class BadPortTests(Base):
    def test_bad_ports_raise_value_error(self):
        for bad in (True, False, -1, 1, 80, 1023, 65536, 70000, '8840', 8840.0, None, [], {}):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    proto.PrototypeServer(self.root, port=bad)

    def test_bad_port_through_serve_prototype_is_value_error(self):
        with self.assertRaises(ValueError):
            proto.serve_prototype(SESSION, str(self.root), 'store', self.runtime,
                                  alive=lambda: True, out=io.StringIO(), port=80)


class ReadyLineTests(Base):
    def test_fixed_port_ready_line(self):
        port = free_port()
        line, _ = self.run_serve(port=port)
        self.assertTrue(line['ok'])
        self.assertEqual(line['port'], port)
        self.assertIs(line['fixed_port'], True)
        # SKILLS-158: origin is the same address plus the launch's key as its one path segment.
        self.assertRegex(line['origin'], r'\Ahttp://127\.0\.0\.1:%d/[A-Za-z0-9_-]{43}/\Z' % port)
        self.assertEqual(line['ssh_line'], 'ssh -L %d:127.0.0.1:%d <host>' % (port, port))

    def test_default_ready_line_keeps_every_old_key(self):
        line, _ = self.run_serve()
        self.assertIs(line['fixed_port'], False)
        for key in ('ok', 'origin', 'port', 'ssh_line'):
            self.assertIn(key, line)
        self.assertEqual(set(line), {'ok', 'origin', 'port', 'ssh_line', 'fixed_port'})
        self.assertRegex(line['origin'], r'\Ahttp://127\.0\.0\.1:%d/[A-Za-z0-9_-]{43}/\Z' % line['port'])


class RunPrototypeTests(unittest.TestCase):
    def test_equal_ports_refused_at_run_time(self):
        with self.assertRaises(IdeaError) as ctx:
            idea._fixed_ports(dict(browser_port=8840, prototype_port=8840))
        self.assertEqual(ctx.exception.code, 'invalid_config')

    def test_distinct_ports_and_mode_pass_through(self):
        self.assertEqual(idea._fixed_ports(dict(browser_port=8840, prototype_port=8841, browser_mode='link')),
                         (8840, 8841, 'link'))
        self.assertEqual(idea._fixed_ports({}), (None, None, None))
        self.assertEqual(idea._fixed_ports(dict(prototype_port=8841)), (None, 8841, None))
        self.assertEqual(idea._fixed_ports(dict(browser_port=8840)), (8840, None, None))

    def test_one_port_null_is_not_a_collision(self):
        self.assertEqual(idea._fixed_ports(dict(browser_port=None, prototype_port=8841))[1], 8841)

    def run_with(self, config):
        calls = []

        def fake_serve(*a, **kw):
            calls.append(kw)
            return dict(ok=True, code='stopped')
        with mock.patch.object(idea, 'launcher_configuration', return_value=('store', 'runtime', {}, 'exe')), \
                mock.patch.object(idea, '_configuration_source', return_value=(config,)), \
                mock.patch.object(proto, 'serve_prototype', fake_serve):
            return idea.run_prototype(mock.Mock(session=SESSION, dir='/x')), calls

    def test_run_prototype_refuses_equal_ports(self):
        result, calls = self.run_with(dict(browser_port=8840, prototype_port=8840))
        self.assertFalse(result['ok'])
        self.assertEqual(result['error']['code'], 'invalid_config')
        self.assertEqual(calls, [])

    def test_run_prototype_passes_the_fixed_port(self):
        result, calls = self.run_with(dict(prototype_port=8841))
        self.assertTrue(result['ok'])
        self.assertEqual(calls, [dict(port=8841)])

    def test_run_prototype_without_a_port_passes_none(self):
        result, calls = self.run_with({})
        self.assertTrue(result['ok'])
        self.assertEqual(calls, [{}])
        _, calls = self.run_with(dict(prototype_port=None))
        self.assertEqual(calls, [{}])

    def test_run_prototype_refuses_a_bad_prototype_port(self):
        result, calls = self.run_with(dict(prototype_port=80))
        self.assertEqual(result['error']['code'], 'invalid_config')
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
