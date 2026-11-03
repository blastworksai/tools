"""Security acceptance tests; all state, certificates and listeners are isolated."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import ssl
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

import aiohttp
from aiohttp import web
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from usage_service import security
from usage_service.protocol import PROTOCOL, ServiceError
from usage_service.security import (
    FailureLimiter, Security, bearer, check_private, endpoint, ensure_certificate,
    matches, pin, private_directory, private_staging_directory, secret, tls_context, validate_invitation,
    validate_local, verifier, write_private,
)
from usage_service.store import Store


class SecurityStateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "private"
        self.now = 1_800_000_000.0
        self.store = Store(self.root, clock=lambda: self.now)
        self.addCleanup(self.store.close)
        self.security = Security(self.store, self.root, clock=lambda: self.now)
        self.group = self.store.identity()["group_id"]

    def invitation(self):
        return self.security.offer("https://127.0.0.1:40443", self.group)

    def pair(self):
        invite = self.invitation()
        device = str(uuid4())
        return device, self.security.consume(invite["secret"], device)

    def assert_safe_error(self, callback, code=None):
        with self.assertRaises(ServiceError) as caught:
            callback()
        if code is not None:
            self.assertEqual(caught.exception.code, code)
        rendered = json.dumps(caught.exception.public()) + str(caught.exception)
        self.assertNotIn(str(self.root), rendered)
        self.assertNotIn(self.security.local_token, rendered)
        self.assertNotIn("SENTINEL", rendered)
        return caught.exception

    def test_invitation_consumed_once_and_only_verifiers_persist(self):
        invitation = self.invitation()
        self.assertEqual(validate_invitation(invitation, now_ms=int(self.now * 1000)), invitation)
        device = str(uuid4())
        result = self.security.consume(invitation["secret"], device)
        self.assertEqual(result["protocol"], PROTOCOL)
        self.assertEqual(result["device_id"], self.store.identity()["device_id"])
        self.assertEqual(result["group_id"], self.group)
        self.assertNotEqual(result["credential"], invitation["secret"])
        authority = self.security.authenticate(result["credential"])
        self.assertEqual(authority.device_id, device)
        self.assertEqual(authority.group_id, self.group)
        self.assertFalse(authority.local)
        peers = self.store.peers()
        self.assertEqual(len(peers), 1)
        self.assertTrue(matches(result["credential"], peers[0]["credential_hash"]))
        self.assertNotIn(result["credential"], json.dumps(peers))
        self.assert_safe_error(lambda: self.security.consume(invitation["secret"], str(uuid4())), "unauthorized")
        self.assert_safe_error(lambda: self.security.authenticate(invitation["secret"]), "unauthorized")
        diagnostics = json.dumps(self.store.diagnostics())
        for sensitive in (invitation["secret"], result["credential"], peers[0]["credential_hash"]):
            self.assertNotIn(sensitive, diagnostics)

    def test_expiry_at_exact_deadline_and_no_peer_created(self):
        invite = self.invitation()
        self.now += 600
        self.assert_safe_error(lambda: validate_invitation(invite, now_ms=int(self.now * 1000)), "expired")
        self.assert_safe_error(lambda: self.security.consume(invite["secret"], str(uuid4())), "unauthorized")
        self.assertEqual(self.store.peers(), [])

    def test_revocation_immediately_invalidates_credential(self):
        device, paired = self.pair()
        self.security.authenticate(paired["credential"])
        self.store.revoke_peer(device)
        self.assert_safe_error(lambda: self.security.authenticate(paired["credential"]), "unauthorized")

    def test_each_peer_has_distinct_device_bound_credential(self):
        first_device, first = self.pair()
        second_device, second = self.pair()
        self.assertNotEqual(first["credential"], second["credential"])
        self.assertEqual(self.security.authenticate(first["credential"]).device_id, first_device)
        self.assertEqual(self.security.authenticate(second["credential"]).device_id, second_device)
        self.store.revoke_peer(first_device)
        self.assertEqual(self.security.authenticate(second["credential"]).device_id, second_device)

    def test_invitation_cannot_take_over_existing_peer_identity(self):
        device, paired = self.pair()
        invite = self.invitation()
        self.assert_safe_error(lambda: self.security.consume(invite["secret"], device), "unauthorized")
        self.assertEqual(self.security.authenticate(paired["credential"]).device_id, device)
        fresh_device = str(uuid4())
        fresh = self.security.consume(invite["secret"], fresh_device)
        self.assertEqual(self.security.authenticate(fresh["credential"]).device_id, fresh_device)

    def test_local_and_peer_tokens_are_not_interchangeable(self):
        _, paired = self.pair()
        host = "127.0.0.1:30303"
        owner = self.security.authenticate_local(host, None, "Bearer " + self.security.local_token, host)
        self.assertTrue(owner.local)
        self.assertEqual(owner.role, "owner")
        self.assert_safe_error(lambda: self.security.authenticate(self.security.local_token), "unauthorized")
        self.assert_safe_error(lambda: self.security.authenticate_local(host, None, "Bearer " + paired["credential"], host),
                               "unauthorized")
        self.assert_safe_error(lambda: self.security.consume(self.security.local_token, str(uuid4())), "unauthorized")
        self.assert_safe_error(lambda: self.security.consume(paired["credential"], str(uuid4())), "unauthorized")

    def test_local_capability_rotates_but_peer_credential_survives_restart(self):
        _, paired = self.pair()
        old = self.security.local_token
        restarted = Security(self.store, self.root, clock=lambda: self.now)
        self.assertNotEqual(old, restarted.local_token)
        self.assertEqual((self.root / "local.token").read_text(), restarted.local_token)
        check_private(self.root / "local.token")
        host = "[::1]:30303"
        with self.assertRaises(ServiceError):
            restarted.authenticate_local(host, None, "Bearer " + old, host)
        self.assertFalse(restarted.authenticate(paired["credential"]).local)

    def test_pairing_cannot_claim_server_identity_or_invalid_uuid(self):
        invite = self.invitation()
        self.assert_safe_error(lambda: self.security.consume(invite["secret"], self.store.identity()["device_id"]), "unauthorized")
        self.assert_safe_error(lambda: self.security.consume(invite["secret"], "SENTINEL/private/path"), "unauthorized")
        self.security.consume(invite["secret"], str(uuid4()))

    def test_auth_and_pair_failures_are_rate_limited(self):
        _, paired = self.pair()
        for _ in range(8):
            self.assertEqual(self.assert_safe_error(lambda: self.security.authenticate("invalid")).status, 401)
        self.assertEqual(self.assert_safe_error(lambda: self.security.authenticate("invalid")).status, 429)
        # The limiter only counts failures: a valid credential is never locked out.
        self.assertFalse(self.security.authenticate(paired["credential"]).local)
        for _ in range(5):
            self.assertEqual(self.assert_safe_error(lambda: self.security.consume("invalid", str(uuid4()))).status, 401)
        self.assertEqual(self.assert_safe_error(lambda: self.security.consume("invalid", str(uuid4()))).status, 429)

    def test_local_token_failures_never_lock_out_the_owner(self):
        host = "127.0.0.1:30303"
        for _ in range(32):
            self.assertEqual(self.assert_safe_error(
                lambda: self.security.authenticate_local(host, None, "Bearer " + secret(), host)).status, 401)
        self.assertTrue(self.security.authenticate_local(host, None, "Bearer " + self.security.local_token, host).local)

    def test_invitation_validation_checks_entire_schema(self):
        invite = self.invitation()
        changes = [
            {"endpoint": "https://user:password@example.test"}, {"fingerprint": "not-a-pin"},
            {"device_id": "not-a-device"}, {"secret": "short"}, {"group_id": "../SENTINEL"},
            {"protocol": True}, {"protocol": 999}, {"expires_at_ms": True},
            {"expires_at_ms": int(self.now * 1000)}, {"unexpected": "SENTINEL"},
        ]
        for changeset in changes:
            with self.subTest(changeset=changeset):
                self.assert_safe_error(lambda: validate_invitation(invite | changeset, now_ms=int(self.now * 1000)))
        incomplete = dict(invite)
        del incomplete["device_id"]
        self.assert_safe_error(lambda: validate_invitation(incomplete, now_ms=int(self.now * 1000)))
        # The hub's clock sets expiry; a member whose clock runs behind still accepts it.
        ahead = invite | {"expires_at_ms": int(self.now * 1000) + 3_600_000}
        self.assertEqual(validate_invitation(ahead, now_ms=int(self.now * 1000))["expires_at_ms"], ahead["expires_at_ms"])


class BoundaryTests(unittest.TestCase):
    def test_bootstrap_helpers_import_without_site_packages(self):
        result = subprocess.run(
            [sys.executable, "-S", "-c",
             "from usage_service.security import secret, private_directory, write_private, check_private; "
             "assert len(secret()) == 43"],
            cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, "stdlib-only security bootstrap import failed")

    def test_strict_https_origin(self):
        for value, expected in [
            ("https://example.test", "https://example.test"),
            ("https://EXAMPLE.test:443/", "https://example.test:443"),
            ("https://127.0.0.1:40443", "https://127.0.0.1:40443"),
            ("https://[::1]:40443/", "https://[::1]:40443"),
        ]:
            self.assertEqual(endpoint(value), expected)
        invalid = [
            None, "", "http://example.test", "HTTPS://example.test", "file:///private",
            "https://user@example.test", "https://user:pass@example.test", "https://example.test#fragment",
            "https://example.test#", "https://example.test?", "https://example.test?token=SENTINEL",
            "https://example.test/path", "https://example.test//", "https://example.test\\evil",
            " https://example.test", "https://example.test\n", "https://example.test:\t443",
            "https://example.test:0", "https://example.test:65536", "https://example.test:",
            "https://example.test:0443", "https://example.test:+443", "https://example.test.",
            "https://exa_mple.test", "https://example..test", "https://-example.test", "https://éxample.test",
            "https://127.1", "https://2130706433", "https://0177.0.0.1", "https://0x7f000001",
            "https://%31%32%37.0.0.1", "https://[::1]evil", "https://[fe80::1%25eth0]",
            "https://::1", "https://0.0.0.0", "https://[::]", "https://224.0.0.1",
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ServiceError) as caught:
                endpoint(value)
            self.assertEqual(caught.exception.code, "invalid_request")
            self.assertNotIn("SENTINEL", str(caught.exception))

    def test_pins_are_exact_sha256_hex(self):
        self.assertEqual(pin("AB" * 32), b"\xab" * 32)
        for value in (None, b"a" * 64, "a" * 63, "a" * 65, "g" * 64, "aa:" * 32, "a" * 64 + "\n"):
            with self.subTest(value=value), self.assertRaises(ServiceError):
                pin(value)

    def test_bounded_secrets_and_constant_time_hash_comparison(self):
        token = secret()
        self.assertEqual(len(token), 43)
        self.assertTrue(matches(token, verifier(token)))
        self.assertFalse(matches(secret(), verifier(token)))
        for value in (None, "", "a" * 42, "a" * 129, "é" * 43, "a" * 43 + "\n"):
            self.assertFalse(matches(value, verifier(token)))
            with self.assertRaises(ServiceError):
                verifier(value)
        with patch.object(security.hmac, "compare_digest", wraps=security.hmac.compare_digest) as compare:
            self.assertTrue(matches(token, verifier(token)))
            compare.assert_called_once()
        for header in (None, token, "bearer " + token, "Bearer  " + token, "Bearer " + token + ",Bearer " + token):
            with self.assertRaises(ServiceError):
                bearer(header)

    def test_local_host_origin_and_capability_boundary(self):
        token = secret()
        host = "127.0.0.1:30001"
        validate_local(host, None, "Bearer " + token, host, token)
        for supplied_host, origin, expected in [
            (host, "", host), (host, "null", host), (host, "https://example.test", host),
            ("localhost:30001", None, host), ("127.0.0.1:30002", None, host),
            ("127.0.0.1:30001.attacker.test", None, host), (host + " ", None, host),
            ("0.0.0.0:30001", None, "0.0.0.0:30001"),
            ("example.test:30001", None, "example.test:30001"),
            ("127.0.0.1", None, "127.0.0.1"), ("127.0.0.1:030001", None, "127.0.0.1:030001"),
        ]:
            with self.subTest(host=supplied_host, origin=origin), self.assertRaises(ServiceError):
                validate_local(supplied_host, origin, "Bearer " + token, expected, token)

    def test_failure_limiter_is_bounded_and_expires_without_early_eviction(self):
        now = [0.0]
        limiter = FailureLimiter(limit=2, global_limit=4, max_keys=2, window=10, clock=lambda: now[0])
        limiter.failure("a")
        limiter.failure("b")
        with self.assertRaises(ServiceError) as caught:
            limiter.check("new-rotating-address")
        self.assertEqual(caught.exception.status, 429)
        limiter.check("a")
        limiter.failure("a")
        with self.assertRaises(ServiceError):
            limiter.check("a")
        limiter.failure("c")
        self.assertEqual(len(limiter._buckets), 2)
        with self.assertRaises(ServiceError):
            limiter.check("b")
        now[0] = 10
        limiter.check("a")
        limiter.check("c")
        self.assertEqual(len(limiter._buckets), 0)
        with self.assertRaises(ServiceError):
            limiter.check("x" * 257)


class PrivateFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "private"
        private_directory(self.root)

    def test_atomic_private_files_and_directories(self):
        staged = private_staging_directory(self.root, ".stage-")
        target = staged / "capability"
        write_private(target, b"first secret")
        check_private(target)
        write_private(target, b"second secret")
        self.assertEqual(target.read_bytes(), b"second secret")
        self.assertEqual(sorted(p.name for p in staged.iterdir()), ["capability"])
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(staged.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    @unittest.skipUnless(os.name == "posix", "POSIX permissions")
    def test_insecure_existing_modes_and_wrong_owner_are_rejected_not_repaired(self):
        target = self.root / "capability"
        write_private(target, b"private")
        target.chmod(0o644)
        with self.assertRaises(ServiceError):
            check_private(target)
        with self.assertRaises(ServiceError):
            write_private(target, b"replacement")
        self.assertEqual(target.read_bytes(), b"private")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
        target.chmod(0o600)
        with patch.object(security.os, "getuid", return_value=target.stat().st_uid + 1):
            with self.assertRaises(ServiceError):
                check_private(target)
        self.root.chmod(0o755)
        with self.assertRaises(ServiceError):
            private_directory(self.root)
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o755)

    @unittest.skipUnless(os.name == "posix", "POSIX link creation")
    def test_symlink_hardlink_and_directory_destinations_fail_closed(self):
        target = self.root / "target"
        write_private(target, b"original")
        linked = self.root / "linked"
        linked.symlink_to(target)
        with self.assertRaises(ServiceError):
            write_private(linked, b"overwritten")
        linked.unlink()
        os.link(target, linked)
        with self.assertRaises(ServiceError):
            write_private(linked, b"overwritten")
        self.assertEqual(target.read_bytes(), b"original")
        with self.assertRaises(ServiceError):
            write_private(self.root, b"not a directory")

    def test_os_failures_expose_no_path_or_exception_detail(self):
        with patch.object(security.tempfile, "mkstemp", side_effect=OSError("SENTINEL /private/location")):
            with self.assertRaises(ServiceError) as caught:
                write_private(self.root / "secret", b"SENTINEL")
        self.assertEqual(caught.exception.code, "setup_required")
        self.assertNotIn("SENTINEL", json.dumps(caught.exception.public()))
        self.assertNotIn(str(self.root), str(caught.exception))
        self.assertTrue(caught.exception.__suppress_context__)

    def test_windows_acl_failure_has_no_chmod_fallback_or_raw_diagnostic(self):
        result = subprocess.CompletedProcess([], 1, stdout="SENTINEL", stderr="private/path")
        with patch.dict(os.environ, {"SystemRoot": str(Path(self.temporary.name).absolute())}), \
                patch.object(security.subprocess, "run", return_value=result), \
                patch.object(security.os, "chmod") as chmod:
            with self.assertRaises(ServiceError) as caught:
                security._windows_acl(self.root, protect=True)
        chmod.assert_not_called()
        self.assertNotIn("SENTINEL", str(caught.exception))
        self.assertNotIn("private/path", str(caught.exception))

    @unittest.skipUnless(os.name == "nt", "Windows SID DACL enforcement")
    def test_windows_acl_rejects_added_everyone_access(self):
        target = private_staging_directory(self.root, ".stage-") / "capability"
        write_private(target, b"private")
        executable = Path(os.environ["SystemRoot"]) / "System32/icacls.exe"
        subprocess.run([str(executable), str(target), "/grant", "*S-1-1-0:(R)"],
                       capture_output=True, check=True, creationflags=subprocess.CREATE_NO_WINDOW)
        with self.assertRaises(ServiceError):
            check_private(target)
        with self.assertRaises(ServiceError):
            write_private(target, b"must not leak")


class CertificateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "private"

    def test_stable_certificate_key_pin_and_tls_minimum(self):
        first = ensure_certificate(self.root)
        second = ensure_certificate(self.root)
        self.assertEqual(first, second)
        for name in ("key", "cert"):
            check_private(first[name])
        cert = x509.load_pem_x509_certificate(first["cert"].read_bytes())
        self.assertEqual(pin(first["fingerprint"]), cert.fingerprint(hashes.SHA256()))
        self.assertEqual(tls_context(self.root).minimum_version, ssl.TLSVersion.TLSv1_2)
        self.assertNotIn(str(self.root), cert.subject.rfc4514_string())

    def test_corrupt_partial_and_mismatched_pairs_never_silently_rotate(self):
        certificate = ensure_certificate(self.root)
        original_cert = certificate["cert"].read_bytes()
        original_key = certificate["key"].read_bytes()
        for replacement in (b"SENTINEL not a key", ec.generate_private_key(ec.SECP256R1()).private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())):
            write_private(certificate["key"], replacement)
            with self.assertRaises(ServiceError) as caught:
                ensure_certificate(self.root)
            self.assertEqual(caught.exception.code, "setup_required")
            self.assertNotIn("SENTINEL", str(caught.exception))
            self.assertEqual(certificate["cert"].read_bytes(), original_cert)
        write_private(certificate["key"], original_key)
        certificate["cert"].unlink()
        with self.assertRaises(ServiceError):
            ensure_certificate(self.root)
        self.assertFalse(certificate["cert"].exists())
        self.assertEqual(certificate["key"].read_bytes(), original_key)

    def test_expired_certificate_refuses_startup(self):
        certificate = ensure_certificate(self.root)
        key = serialization.load_pem_private_key(certificate["key"].read_bytes(), password=None)
        now = datetime.now(timezone.utc)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "USAGE test")])
        expired = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(days=2))
                   .not_valid_after(now - timedelta(days=1))
                   .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                   .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                   .sign(key, hashes.SHA256()))
        write_private(certificate["cert"], expired.public_bytes(serialization.Encoding.PEM))
        with self.assertRaises(ServiceError):
            tls_context(self.root)


class RealTLSTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "private"
        self.now = 1_800_000_000.0
        self.store = Store(self.root, clock=lambda: self.now)
        self.addCleanup(self.store.close)
        self.security = Security(self.store, self.root, clock=lambda: self.now)
        self.invite = self.security.offer("https://127.0.0.1:40443", self.store.identity()["group_id"])
        self.paired_device = str(uuid4())
        self.paired = self.security.consume(self.invite["secret"], self.paired_device)
        self.requests = 0

        async def authenticate(request):
            self.requests += 1
            try:
                authority = self.security.authenticate(bearer(request.headers.get("Authorization")))
                return web.json_response({"device_id": authority.device_id})
            except ServiceError as error:
                return web.json_response(error.public(), status=error.status)

        async def consume(request):
            self.requests += 1
            try:
                data = await request.json()
                result = self.security.consume(data["secret"], data["device_id"])
                return web.json_response(result)
            except ServiceError as error:
                return web.json_response(error.public(), status=error.status)

        app = web.Application()
        app.router.add_get("/auth", authenticate)
        app.router.add_post("/pair", consume)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        self.addAsyncCleanup(self.runner.cleanup)
        await web.TCPSite(self.runner, "127.0.0.1", 0, ssl_context=tls_context(self.root)).start()
        port = self.runner.addresses[0][1]
        self.url = f"https://127.0.0.1:{port}"
        self.session = aiohttp.ClientSession(trust_env=False, timeout=aiohttp.ClientTimeout(total=5))
        self.addAsyncCleanup(self.session.close)
        self.fingerprint = aiohttp.Fingerprint(pin(self.invite["fingerprint"]))

    async def test_real_tls_correct_pin_wrong_pin_and_revoked_peer(self):
        headers = {"Authorization": "Bearer " + self.paired["credential"]}
        async with self.session.get(self.url + "/auth", headers=headers, ssl=self.fingerprint, allow_redirects=False) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual((await response.json())["device_id"], self.paired_device)
        requests_before = self.requests
        with self.assertRaises(aiohttp.ServerFingerprintMismatch):
            async with self.session.get(self.url + "/auth", headers=headers,
                                        ssl=aiohttp.Fingerprint(b"\0" * 32), allow_redirects=False):
                self.fail("wrong pin reached HTTP")
        self.assertEqual(self.requests, requests_before)
        self.store.revoke_peer(self.paired_device)
        async with self.session.get(self.url + "/auth", headers=headers, ssl=self.fingerprint, allow_redirects=False) as response:
            self.assertEqual(response.status, 401)
            body = await response.text()
            self.assertNotIn(self.paired["credential"], body)
            self.assertNotIn(str(self.root), body)

    async def test_real_tls_expired_invitation_has_sanitized_failure(self):
        invite = self.security.offer(self.url, self.store.identity()["group_id"])
        self.now += 600
        async with self.session.post(self.url + "/pair", json={"secret": invite["secret"], "device_id": str(uuid4())},
                                     ssl=self.fingerprint, allow_redirects=False) as response:
            self.assertEqual(response.status, 401)
            body = await response.text()
            self.assertNotIn(invite["secret"], body)
            self.assertNotIn(str(self.root), body)
            self.assertEqual(json.loads(body)["error"]["code"], "unauthorized")


if __name__ == "__main__":
    unittest.main()
