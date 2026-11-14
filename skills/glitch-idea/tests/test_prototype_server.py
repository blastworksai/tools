"""Sealed prototype server: confinement, headers, no cookies, loopback bind, liveness stop, per-launch key."""
import http.client
import io
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sys
import tempfile
import threading
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
import idea_prototype as proto
from idea_domain import IdeaError

SESSION = 'session_' + '0' * 32
RESPONSES = []


def private_dir(path):
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='proto-')).resolve()
        os.chmod(self.tmp, 0o700)
        self.runtime = private_dir(self.tmp / 'runtime')
        self.root = private_dir(self.runtime / 'prototypes' / 'idea_x')
        (self.root / 'index.html').write_text('<h1>hi</h1>')
        (self.root / 'app.js').write_text('1')
        (self.root / 'sub').mkdir()
        (self.root / 'sub' / 'index.html').write_text('sub')
        (self.tmp / 'secret.txt').write_text('secret')
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def start(self):
        server = proto.PrototypeServer(proto.validate_directory(str(self.root), self.runtime))
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        return server

    def get(self, server, path, method='GET', headers=None, keyed=True):
        """Request path behind the server's key; keyed=False sends the target exactly as given."""
        conn = http.client.HTTPConnection('127.0.0.1', server.server_address[1], timeout=5)
        try:
            conn.request(method, ('/' + server.key + path) if keyed else path, headers=headers or {})
            resp = conn.getresponse()
            body = resp.read()
            RESPONSES.append(resp)
            return resp, body
        finally:
            conn.close()


class ConfinementTests(Base):
    def test_serves_file_and_index(self):
        server = self.start()
        resp, body = self.get(server, '/app.js')
        self.assertEqual((resp.status, body), (200, b'1'))
        resp, body = self.get(server, '/')
        self.assertEqual((resp.status, body), (200, b'<h1>hi</h1>'))
        resp, body = self.get(server, '/sub/')
        self.assertEqual((resp.status, body), (200, b'sub'))
        resp, body = self.get(server, '/app.js', 'HEAD')
        self.assertEqual((resp.status, body), (200, b''))

    def test_binds_loopback_only(self):
        server = self.start()
        self.assertEqual(server.server_address[0], '127.0.0.1')
        self.assertNotEqual(server.server_address[1], 0)

    def test_traversal_encodings_refused(self):
        server = self.start()
        for path in ('/../secret.txt', '/sub/../../secret.txt', '/%2e%2e/secret.txt', '/%2E%2E/secret.txt',
                     '/..%2fsecret.txt', '/sub/%2e%2e%2f%2e%2e%2fsecret.txt', '/..%5csecret.txt',
                     '//etc/passwd', '/%00', '/.%2e/secret.txt', '/\\..\\secret.txt'):
            resp, body = self.get(server, path)
            self.assertIn(resp.status, (400, 403, 404), path)
            self.assertNotIn(b'secret', body, path)

    def test_absolute_path_refused(self):
        server = self.start()
        resp, body = self.get(server, '/' + str(self.tmp / 'secret.txt'))
        self.assertEqual(resp.status, 404)
        self.assertNotIn(b'secret', body)

    def test_symlink_component_refused(self):
        os.symlink(self.tmp, self.root / 'link')
        os.symlink(self.tmp / 'secret.txt', self.root / 'file-link')
        server = self.start()
        for path in ('/link/secret.txt', '/file-link', '/link'):
            resp, body = self.get(server, path)
            self.assertEqual(resp.status, 403, path)
            self.assertNotIn(b'secret', body)

    def test_file_outside_folder_refused(self):
        server = self.start()
        resp, _ = self.get(server, '/../../../secret.txt')
        self.assertIn(resp.status, (403, 404))

    def test_wrong_host_refused(self):
        server = self.start()
        resp, _ = self.get(server, '/app.js', headers={'Host': 'evil.example'})
        self.assertEqual(resp.status, 421)

    def test_methods_other_than_get_head_are_405(self):
        server = self.start()
        for method in ('POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'):
            resp, _ = self.get(server, '/app.js', method)
            self.assertEqual(resp.status, 405, method)


class HeaderTests(Base):
    def test_headers_on_200_and_404_and_405(self):
        server = self.start()
        for path, method, status in (('/app.js', 'GET', 200), ('/missing', 'GET', 404), ('/app.js', 'POST', 405),
                                     ('/../x', 'GET', 403)):
            resp, _ = self.get(server, path, method)
            self.assertEqual(resp.status, status)
            self.assertEqual(resp.getheader('Content-Security-Policy'), proto.CSP)
            self.assertEqual(resp.getheader('X-Content-Type-Options'), 'nosniff')
            self.assertEqual(resp.getheader('Referrer-Policy'), 'no-referrer')
            self.assertEqual(resp.getheader('Cache-Control'), 'no-store')

    def test_no_set_cookie_even_with_cookie_header(self):
        server = self.start()
        for path in ('/app.js', '/missing', '/'):
            resp, _ = self.get(server, path, headers={'Cookie': 'session=abc; a=b'})
            self.assertIsNone(resp.getheader('Set-Cookie'))

    def test_zz_sweep_no_response_ever_set_a_cookie(self):
        self.assertTrue(RESPONSES)
        for resp in RESPONSES:
            self.assertIsNone(resp.getheader('Set-Cookie'))
            self.assertEqual(resp.getheader('Content-Security-Policy'), proto.CSP)


class DirectoryValidationTests(Base):
    def test_group_or_other_bits_refused(self):
        for mode in (0o750, 0o705, 0o755, 0o770):
            os.chmod(self.root, mode)
            with self.assertRaises(IdeaError) as ctx:
                proto.validate_directory(str(self.root), self.runtime)
            self.assertEqual(ctx.exception.code, 'unsafe_prototype_dir', oct(mode))

    def test_outside_prototypes_refused(self):
        other = private_dir(self.tmp / 'elsewhere')
        for bad in (str(other), str(self.runtime / 'prototypes'), str(self.runtime), 'relative/dir'):
            with self.assertRaises(IdeaError) as ctx:
                proto.validate_directory(bad, self.runtime)
            self.assertEqual(ctx.exception.code, 'unsafe_prototype_dir', bad)

    def test_symlinked_folder_refused(self):
        link = self.runtime / 'prototypes' / 'idea_link'
        os.symlink(self.root, link)
        with self.assertRaises(IdeaError) as ctx:
            proto.validate_directory(str(link), self.runtime)
        self.assertEqual(ctx.exception.code, 'unsafe_prototype_dir')

    def test_invalid_session_refused(self):
        with self.assertRaises(IdeaError) as ctx:
            proto.serve_prototype('nope', str(self.root), 'store', self.runtime, alive=lambda: True)
        self.assertEqual(ctx.exception.code, 'invalid_session')
        with self.assertRaises(IdeaError) as ctx:
            proto.serve_prototype(SESSION, str(self.root), 'store', self.runtime, alive=lambda: False)
        self.assertEqual(ctx.exception.code, 'invalid_session')

    def test_start_refuses_unsafe_dir(self):
        os.chmod(self.root, 0o755)
        with self.assertRaises(IdeaError) as ctx:
            proto.serve_prototype(SESSION, str(self.root), 'store', self.runtime, alive=lambda: True)
        self.assertEqual(ctx.exception.code, 'unsafe_prototype_dir')


class LivenessTests(Base):
    def run_serve(self, alive, **kw):
        out = io.StringIO()
        result = {}

        def target():
            result['value'] = proto.serve_prototype(SESSION, str(self.root), 'store', self.runtime,
                                                    alive=alive, out=out, poll=.05, **kw)
        thread = threading.Thread(target=target, daemon=True)
        thread.start()
        return thread, out, result

    def test_prints_start_line_and_stops_when_session_ends(self):
        state = {'live': True, 'calls': 0}

        def alive():
            state['calls'] += 1
            return state['live']
        thread, out, result = self.run_serve(alive)
        for _ in range(100):
            if out.getvalue():
                break
            threading.Event().wait(.05)
        line = json.loads(out.getvalue().splitlines()[0])
        self.assertTrue(line['ok'])
        self.assertTrue(line['origin'].startswith('http://127.0.0.1:%d/' % line['port']))
        self.assertEqual(line['ssh_line'], 'ssh -L %d:127.0.0.1:%d <host>' % (line['port'], line['port']))
        conn = http.client.HTTPConnection('127.0.0.1', line['port'], timeout=5)
        conn.request('GET', line['origin'][len('http://127.0.0.1:%d' % line['port']):] + 'app.js')
        resp = conn.getresponse()
        self.assertEqual(resp.read(), b'1')
        RESPONSES.append(resp)
        conn.close()
        state['live'] = False
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result['value'], dict(ok=True, code='stopped'))
        with self.assertRaises(OSError):
            http.client.HTTPConnection('127.0.0.1', line['port'], timeout=1).request('GET', '/')

    def test_liveness_error_stops_server(self):
        count = {'n': 0}

        def alive():
            count['n'] += 1
            if count['n'] > 2:
                raise OSError('owner gone')
            return True
        thread, _, result = self.run_serve(alive)
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result['value']['code'], 'stopped')

    def test_max_lifetime_backstop(self):
        thread, _, result = self.run_serve(lambda: True, max_lifetime=0.2)
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result['value']['code'], 'stopped')


def shape(resp, body):
    """Everything a client can tell two answers apart by, except the Date."""
    return resp.status, body, sorted((k.lower(), v) for k, v in resp.getheaders() if k.lower() != 'date')


def wait_for_start_line(out):
    for _ in range(100):
        if out.getvalue():
            break
        threading.Event().wait(.05)
    return json.loads(out.getvalue().splitlines()[0])


class KeyTests(Base):
    """SKILLS-158: no request without the launch's key is served, and a refusal says nothing."""

    def other_key(self, server):
        key = server.key
        return ('A' if key[0] != 'A' else 'B') + key[1:]

    def targets_without_the_key(self, server, name):
        key = server.key
        swapped = key.swapcase()
        encoded = ''.join('%%%02X' % ord(c) for c in key)
        yield '/' + name
        yield '/' + self.other_key(server) + '/' + name
        yield '/' + key[:-1] + '/' + name
        yield '/' + key + 'x/' + name
        yield '/x/' + key + '/' + name
        yield '/' + name + '?k=' + key
        yield '/' + name + '?' + key
        yield '/' + encoded + '/' + name
        yield '/' + key[0] + '%' + '%02X' % ord(key[1]) + key[2:] + '/' + name
        if swapped != key:
            yield '/' + swapped + '/' + name
        yield '/' + key + '%2F' + name
        yield '/' + key + '\\' + name
        yield '/' + key + '?/' + name
        yield '/' + key + '#/' + name
        yield '/%2F' + key + '/' + name
        yield '/./' + key + '/' + name
        if name:
            yield '/' + key + name

    def test_sweep_no_file_is_ever_served_without_the_key(self):
        (self.root / 'sub' / 'deep.txt').write_text('deep-bytes')
        server = self.start()
        files = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*') if p.is_file())
        self.assertGreaterEqual(len(files), 4)
        contents = [(self.root / name).read_bytes() for name in files]
        tried = 0
        for name in files + ['', 'sub/']:
            for target in self.targets_without_the_key(server, name):
                for method in ('GET', 'HEAD'):
                    resp, body = self.get(server, target, method, keyed=False)
                    tried += 1
                    self.assertEqual(resp.status, 404, (method, target))
                    self.assertEqual(body, b'' if method == 'HEAD' else b'not found', (method, target))
                    for content in contents:
                        self.assertNotIn(content, body, (method, target))
        self.assertGreater(tried, 150)

    def test_wrong_key_is_indistinguishable_from_a_missing_file(self):
        server = self.start()
        missing = shape(*self.get(server, '/no-such-file'))
        self.assertEqual(missing[:2], (404, b'not found'))
        for target in ('/app.js', '/' + self.other_key(server) + '/app.js', '/' + self.other_key(server) + '/no-such-file',
                       '/', '/' + server.key, '/' + self.other_key(server) + '/'):
            self.assertEqual(shape(*self.get(server, target, keyed=False)), missing, target)
        head_missing = shape(*self.get(server, '/no-such-file', 'HEAD'))
        self.assertEqual(head_missing[:2], (404, b''))
        for target in ('/app.js', '/' + self.other_key(server) + '/app.js', '/' + server.key):
            self.assertEqual(shape(*self.get(server, target, 'HEAD', keyed=False)), head_missing, target)

    def test_key_without_trailing_slash_is_not_found(self):
        server = self.start()
        resp, body = self.get(server, '/' + server.key, keyed=False)
        self.assertEqual((resp.status, body), (404, b'not found'))

    def test_everything_loads_under_the_key(self):
        server = self.start()
        for target, content in (('/', b'<h1>hi</h1>'), ('/index.html', b'<h1>hi</h1>'), ('/app.js', b'1'),
                                ('/sub/', b'sub'), ('/sub/index.html', b'sub'), ('/app.js?v=2', b'1')):
            resp, body = self.get(server, target)
            self.assertEqual((resp.status, body), (200, content), target)

    def test_confinement_still_holds_behind_the_right_key(self):
        server = self.start()
        for target in ('/../secret.txt', '/..%2fsecret.txt', '/%2e%2e/secret.txt', '/sub/../../secret.txt'):
            resp, body = self.get(server, target)
            self.assertEqual(resp.status, 403, target)
            self.assertNotIn(b'secret', body)

    def test_right_key_does_not_excuse_a_wrong_host(self):
        server = self.start()
        resp, _ = self.get(server, '/app.js', headers={'Host': 'evil.example'})
        self.assertEqual(resp.status, 421)

    def test_other_methods_answer_405_with_or_without_the_key(self):
        server = self.start()
        with_key = shape(*self.get(server, '/app.js', 'POST'))
        without = shape(*self.get(server, '/app.js', 'POST', keyed=False))
        self.assertEqual(with_key[0], 405)
        self.assertEqual(with_key, without)

    def test_server_is_never_keyless(self):
        root = proto.validate_directory(str(self.root), self.runtime)
        for bad in ('', 'short', 'a' * 31, 'a' * 40 + '/', 'a' * 40 + '?', 'a' * 40 + '%', 'a' * 40 + ' ', 7, b'a' * 40, False):
            with self.assertRaises(ValueError, msg=repr(bad)):
                proto.PrototypeServer(root, key=bad)
        server = proto.PrototypeServer(root, key=None)
        self.addCleanup(server.server_close)
        self.assertRegex(server.key, r'\A[A-Za-z0-9_-]{43}\Z')

    def test_keys_do_not_repeat(self):
        root = proto.validate_directory(str(self.root), self.runtime)
        keys = set()
        for _ in range(20):
            server = proto.PrototypeServer(root)
            keys.add(server.key)
            server.server_close()
        self.assertEqual(len(keys), 20)


class KeyLaunchTests(Base):
    """A key lives for one launch and reaches the start line and nothing else."""

    def launch(self, state, store='store', **kw):
        out, result = io.StringIO(), {}

        def target():
            result['value'] = proto.serve_prototype(SESSION, str(self.root), store, self.runtime,
                                                    alive=lambda: state['live'], out=out, poll=.05, **kw)
        thread = threading.Thread(target=target, daemon=True)
        thread.start()
        return thread, out, wait_for_start_line(out)

    def fetch(self, port, target, method='GET'):
        conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        try:
            conn.request(method, target)
            resp = conn.getresponse()
            body = resp.read()
            RESPONSES.append(resp)
            return resp, body
        finally:
            conn.close()

    def test_first_request_of_a_first_launch_and_the_key_of_the_next(self):
        pattern = re.compile(r'\Ahttp://127\.0\.0\.1:(\d+)/([A-Za-z0-9_-]{43})/\Z')
        # A fixed port, as a seat has: only then may the same port bind again straight after a stop.
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        first_state = {'live': True}
        thread, _, first = self.launch(first_state, port=port)
        match = pattern.match(first['origin'])
        self.assertTrue(match, first['origin'])
        self.assertEqual(int(match.group(1)), first['port'])
        self.assertEqual(set(first), {'ok', 'origin', 'port', 'ssh_line', 'fixed_port'})
        first_key = match.group(2)
        resp, body = self.fetch(first['port'], '/' + first_key + '/app.js')
        self.assertEqual((resp.status, body), (200, b'1'))
        first_state['live'] = False
        thread.join(5)
        self.assertFalse(thread.is_alive())
        second_state = {'live': True}
        thread, _, second = self.launch(second_state, port=first['port'])
        try:
            self.assertEqual(second['port'], first['port'])
            second_key = pattern.match(second['origin']).group(2)
            self.assertNotEqual(second_key, first_key)
            resp, body = self.fetch(second['port'], '/' + first_key + '/app.js')
            self.assertEqual((resp.status, body), (404, b'not found'))
            resp, body = self.fetch(second['port'], '/' + second_key + '/app.js')
            self.assertEqual((resp.status, body), (200, b'1'))
        finally:
            second_state['live'] = False
            thread.join(5)
        self.assertFalse(thread.is_alive())

    def test_key_is_in_no_file_no_argv_no_stderr_and_no_response(self):
        store = private_dir(self.tmp / 'store')
        (store / 'idea.md').write_text('an idea')
        state = {'live': True}
        err, real_stderr = io.StringIO(), sys.stderr
        sys.stderr = err
        try:
            thread, out, line = self.launch(state, store=str(store))
            key = line['origin'].rstrip('/').rsplit('/', 1)[1]
            self.assertRegex(key, r'\A[A-Za-z0-9_-]{43}\Z')
            seen = []
            for target in ('/' + key + '/app.js', '/' + key + '/missing', '/app.js', '/' + key, '/' + key + '/../x'):
                for method in ('GET', 'HEAD', 'POST'):
                    resp, body = self.fetch(line['port'], target, method)
                    seen.append((resp.getheaders(), body))
            state['live'] = False
            thread.join(5)
        finally:
            sys.stderr = real_stderr
        self.assertFalse(thread.is_alive())
        self.assertEqual(err.getvalue(), '')
        self.assertEqual(out.getvalue().count(key), 1)
        for headers, body in seen:
            self.assertNotIn(key.encode(), body)
            self.assertNotIn(key, repr(headers))
        self.assertFalse([arg for arg in sys.argv if key in arg])
        checked = 0
        for path in self.tmp.rglob('*'):
            self.assertNotIn(key, path.name)
            if path.is_file() and not path.is_symlink():
                checked += 1
                self.assertNotIn(key.encode(), path.read_bytes(), str(path))
        self.assertGreaterEqual(checked, 5)


if __name__ == '__main__':
    unittest.main()
