"""Tunnel probe: a sessionless proof only the live owner (holder of the discovery secret) can give."""
import http.client
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
from idea_bridge import BridgeServer
from idea_launch import OwnerService
from idea_runtime import Runtime, RuntimeError as OwnerError, expected_tunnel_proof

NONCE = 'ab' * 16


@unittest.skipUnless(os.name == 'posix', 'owner runtime is POSIX')
class TunnelProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name) / 'ideas'
        self.root = Path(self.temp.name) / 'private'
        self.owner = None
        self.addCleanup(self.stop)
        self.start()

    def start(self):
        runtime = Runtime(self.store, self.root).acquire_owner()
        self.owner = OwnerService(runtime)
        self.owner.start()

    def stop(self):
        if self.owner is not None:
            self.owner.shutdown()
            self.owner = None

    def get(self, query, host=None, headers=None, server=None):
        server = server or self.owner.server
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        h = {'Host': host or server.host}
        h.update(headers or {})
        try:
            conn.request('GET', '/api/v1/tunnel-probe' + query, headers=h)
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def secret(self):
        return Runtime(self.store, self.root).tunnel_probe_secret()

    def test_correct_nonce_gives_expected_proof_without_a_session(self):
        secret = self.secret()
        self.assertRegex(secret, r'^[0-9a-f]{32}$')
        status, body = self.get('?nonce=' + NONCE)  # no cookie, no tab secret, no binding
        self.assertEqual((status, body['ok']), (200, True))
        self.assertEqual(body['proof'], expected_tunnel_proof(secret, NONCE))
        self.assertEqual(body['proof'], __import__('hashlib').sha256((secret + ':' + NONCE).encode()).hexdigest())
        self.assertNotEqual(self.get('?nonce=' + 'cd' * 16)[1]['proof'], body['proof'])

    def test_bad_nonce_refused(self):
        for query in ('', '?nonce=', '?nonce=' + 'AB' * 16, '?nonce=' + 'ab' * 15, '?nonce=' + 'ab' * 17,
                      '?nonce=zz' + 'ab' * 15, '?nonce=' + NONCE + '&nonce=' + NONCE, '?nonce=' + NONCE + '&x=1',
                      '?other=' + NONCE):
            with self.subTest(query=query):
                status, body = self.get(query)
                self.assertEqual((status, body['ok'], body['code']), (400, False, 'invalid_query'))
                self.assertNotIn('proof', body)

    def test_wrong_host_and_origin_refused(self):
        status, body = self.get('?nonce=' + NONCE, host='127.0.0.1:1')
        self.assertEqual((status, body['code']), (403, 'wrong_host'))
        status, body = self.get('?nonce=' + NONCE, headers={'Origin': 'http://evil.example'})
        self.assertEqual((status, body['code']), (403, 'wrong_origin'))

    def test_post_refused(self):
        server = self.owner.server
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        try:
            conn.request('POST', '/api/v1/tunnel-probe?nonce=' + NONCE, b'{}',
                         {'Host': server.host, 'Content-Type': 'application/json', 'Origin': server.origin})
            response = conn.getresponse()
            self.assertEqual(response.status, 405)
            self.assertNotIn(b'proof', response.read())
        finally:
            conn.close()

    def test_server_without_secret_answers_404(self):
        server = BridgeServer()
        import threading
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, daemon=True)
        thread.start()

        def close():
            server.shutdown(); server.server_close(); thread.join(timeout=2)
        self.addCleanup(close)
        status, body = self.get('?nonce=' + NONCE, server=server)
        self.assertEqual((status, body['code']), (404, 'unknown_route'))

    def test_fresh_owner_start_has_a_different_secret(self):
        first = self.secret()
        old_proof = expected_tunnel_proof(first, NONCE)
        self.stop()
        self.start()
        second = self.secret()
        self.assertNotEqual(first, second)
        self.assertNotEqual(self.get('?nonce=' + NONCE)[1]['proof'], old_proof)
        self.assertEqual(self.get('?nonce=' + NONCE)[1]['proof'], expected_tunnel_proof(second, NONCE))

    def test_secret_lives_only_in_the_discovery_record(self):
        secret = self.secret()
        self.get('?nonce=' + NONCE)
        hits = []
        for base in (self.root, self.store):
            for path in Path(base).rglob('*') if Path(base).exists() else ():
                if path.is_file() and secret.encode() in path.read_bytes():
                    hits.append(path.name)
        self.assertEqual(hits, ['discovery.json'])

    def test_old_discovery_without_the_field_is_typed(self):
        runtime = Runtime(self.store, self.root)
        directory = next(p.parent for p in Path(self.root).rglob('discovery.json'))
        path = directory / 'discovery.json'
        original = path.read_text()
        self.addCleanup(lambda: (path.write_text(original), path.chmod(0o600)))
        record = json.loads(original)
        del record['tunnel_probe']
        path.write_text(json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n')
        path.chmod(0o600)
        with self.assertRaises(OwnerError) as caught:
            runtime.tunnel_probe_secret()
        self.assertEqual(caught.exception.code, 'owner_tunnel_probe_unsupported')
        self.assertEqual(runtime.probe_owner()['identity']['service'], 'glitch-idea')  # still readable by the rest

    def test_malformed_field_is_corrupt(self):
        runtime = Runtime(self.store, self.root)
        path = next(Path(self.root).rglob('discovery.json'))
        original = path.read_text()
        self.addCleanup(lambda: (path.write_text(original), path.chmod(0o600)))
        record = json.loads(original)
        record['tunnel_probe'] = 'XYZ'
        path.write_text(json.dumps(record) + '\n')
        path.chmod(0o600)
        with self.assertRaises(OwnerError) as caught:
            runtime.tunnel_probe_secret()
        self.assertEqual(caught.exception.code, 'runtime_corrupt')

    def test_no_owner_is_owner_unavailable(self):
        self.stop()
        with self.assertRaises(OwnerError) as caught:
            self.secret()
        self.assertIn(caught.exception.code, ('owner_unavailable',))


if __name__ == '__main__':
    unittest.main()
