"""Real subprocess/SQLite lifecycle tests; no package downloads during the suite.

The fixture venv exposes the test runner's already-installed distributions via a
.pth file. Production creation is tested separately for consent and hash-only pip
arguments; lifecycle tests still execute the actual immutable daemon/server.
"""
import concurrent.futures
from contextlib import closing
import hashlib
import http.client
import json
import multiprocessing
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4
import venv

from usage_service import runtime
from usage_service.protocol import MAX_BODY, ServiceError, decode, encode
from usage_service.security import check_private, private_directory, write_private
from usage_service.store import Store

PACKAGE = Path(__file__).resolve().parents[1]


def hold_lock(path, ready, release):
    with runtime.OSLock(Path(path)):
        ready.send(True)
        release.recv()


def cli(package, root, command, request=None, raw=None):
    return subprocess.run([sys.executable, "-I", "-B", str(package / "usage_service.py"), command,
                           "--data-root", str(root)], input=raw if raw is not None else encode(request or {}),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, check=False,
                          **({"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}))


def copy_package(destination):
    destination.mkdir()
    for name, content in runtime._sources(PACKAGE).items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    return destination


class RuntimeBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="usage runtime boundaries ")
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / "private companion"

    def result(self, process):
        self.assertEqual(process.stderr, b"")
        self.assertEqual(len(process.stdout.splitlines()), 1)
        result = decode(process.stdout)
        self.assertEqual(process.returncode, 0 if result["ok"] else 1)
        return result

    def test_absent_environment_requires_consent_without_identity_or_install(self):
        result = self.result(cli(PACKAGE, self.root, "ensure", {"client_id": "window:one", "client_kind": "window"}))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "setup_required")
        self.assertEqual(result["state"], "dependency_consent_required")
        self.assertFalse((self.root / "environments").exists())
        self.assertFalse((self.root / "releases").exists())
        self.assertFalse((self.root / "state.sqlite3").exists())
        self.assertNotIn(str(self.root), json.dumps(result))
        check_private(self.root)

    def test_cli_rejects_oversize_invalid_or_secret_argument_without_stderr(self):
        for raw in (b"[]", b"{}{}", b'{"secret":"DO-NOT-ECHO"', b" " * (MAX_BODY + 1)):
            result = self.result(cli(PACKAGE, self.root, "rpc", raw=raw))
            self.assertFalse(result["ok"])
            self.assertNotIn("DO-NOT-ECHO", json.dumps(result))
        result = self.result(cli(PACKAGE, self.root, "SECRET-ARGV"))
        self.assertEqual(result["error"]["code"], "invalid_request")
        self.assertFalse(self.root.exists())

    def test_doctor_and_stop_absent_root_do_not_initialize_state(self):
        self.assertEqual(self.result(cli(PACKAGE, self.root, "doctor")), {"ok": True, "state": "not_initialized"})
        self.assertEqual(self.result(cli(PACKAGE, self.root, "stop")), {"ok": True, "state": "stopped"})
        self.assertFalse(self.root.exists())

    def test_client_and_install_consent_are_strict(self):
        requests = ({}, {"client_id": "x", "client_kind": "peer"},
                    {"client_id": "x", "client_kind": "window", "install_dependencies": "yes"},
                    {"client_id": "x", "client_kind": "window", "token": "secret"})
        for request in requests:
            result = self.result(cli(PACKAGE, self.root, "ensure", request))
            self.assertEqual(result["error"]["code"], "invalid_request")
        self.assertFalse(self.root.exists())

    @unittest.skipUnless(os.name == "posix", "POSIX mode semantics")
    def test_existing_public_root_is_not_repaired(self):
        self.root.mkdir(mode=0o755)
        self.root.chmod(0o755)
        result = self.result(cli(PACKAGE, self.root, "ensure", {"client_id": "x", "client_kind": "window"}))
        self.assertEqual(result["error"]["code"], "setup_required")
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_cross_process_kernel_lock_not_pid_file(self):
        private_directory(self.root)
        context = multiprocessing.get_context("spawn")
        ready_parent, ready_child = context.Pipe(False)
        release_child, release_parent = context.Pipe(False)
        process = context.Process(target=hold_lock, args=(str(self.root / "instance.lock"), ready_child, release_child))
        process.start()
        try:
            self.assertTrue(ready_parent.poll(20))
            self.assertTrue(ready_parent.recv())
            write_private(self.root / "runtime.json", encode({"pid": 1}))
            self.assertTrue(runtime._running(self.root))
            with self.assertRaises(ServiceError):
                with runtime.OSLock(self.root / "instance.lock", timeout=0.05):
                    self.fail("a second process acquired the lifetime lock")
            release_parent.send(True)
            process.join(20)
            self.assertEqual(process.exitcode, 0)
            self.assertFalse(runtime._running(self.root))
            with runtime.OSLock(self.root / "instance.lock"):
                pass
        finally:
            if process.is_alive():
                release_parent.send(True)
                process.join(20)
            ready_parent.close()
            ready_child.close()
            release_parent.close()
            release_child.close()

    def test_hash_locked_install_flags_and_cleanup_on_failed_install(self):
        private_directory(self.root)
        stamp = runtime.source_stamp()
        release = runtime._stage_release(self.root, runtime._sources(PACKAGE), stamp)
        calls = []

        def failed_install(argv, **kwargs):
            calls.append((argv, kwargs))
            return subprocess.CompletedProcess(argv, 1 if "pip" in argv else 0)

        with patch.object(runtime.subprocess, "run", side_effect=failed_install):
            with self.assertRaises(runtime.RuntimeFailure) as caught:
                runtime._stage_environment(self.root, release, stamp, True)
        self.assertEqual(caught.exception.state, "dependency_install_failed")
        self.assertEqual(len(calls), 2)
        command, options = calls[1]
        for argument in ("--isolated", "--require-hashes", "--only-binary=:all:", "--no-compile", "--no-cache-dir"):
            self.assertIn(argument, command)
        self.assertNotIn("shell", options)
        self.assertEqual(options["stdin"], subprocess.DEVNULL)
        self.assertEqual(options["stdout"], subprocess.DEVNULL)
        self.assertEqual(options["stderr"], subprocess.DEVNULL)
        self.assertEqual(options["env"]["TMPDIR"], str(self.root / "tmp"))
        self.assertEqual(list((self.root / "environments").iterdir()), [])
        self.assertFalse((self.root / "state.sqlite3").exists())

    def test_no_console_detached_spawn_options_on_current_platform(self):
        options = runtime.detached_options()
        self.assertTrue(options["close_fds"])
        for key in ("stdin", "stdout", "stderr"):
            self.assertEqual(options[key], subprocess.DEVNULL)
        self.assertNotIn("shell", options)
        if os.name == "nt":
            self.assertTrue(options["creationflags"] & subprocess.CREATE_NO_WINDOW)
            self.assertTrue(options["creationflags"] & subprocess.CREATE_NEW_PROCESS_GROUP)
            # Detached, the venv launcher's child interpreter would get a visible console.
            self.assertFalse(options["creationflags"] & subprocess.DETACHED_PROCESS)
            self.assertNotIn("start_new_session", options)
        else:
            self.assertTrue(options["start_new_session"])
            self.assertNotIn("creationflags", options)

    def test_environment_name_keeps_the_pre_2_0_key_format(self):
        stamp = {"lock_digest": "a" * 64}
        interpreter = {"implementation": sys.implementation.name, "version": list(sys.version_info[:3]),
                       "platform": sys.platform, "cache_tag": sys.implementation.cache_tag}
        self.assertEqual(runtime._environment_name(stamp),
                         "a" * 64 + "-" + hashlib.sha256(encode(interpreter)).hexdigest()[:16])

    def test_loopback_endpoint_rejects_dns_redirect_targets_and_port_aliases(self):
        for endpoint in ("http://localhost:42", "http://127.0.0.1:0042", "http://127.0.0.1:42/",
                         "http://127.0.0.1:65536", "http://127.0.0.1:42@evil.test", "https://127.0.0.1:42",
                         "http://127.0.0.1:42?secret=x", "http://[::1]:42"):
            with self.assertRaises(ServiceError):
                runtime._endpoint(endpoint)
        self.assertEqual(runtime._endpoint("http://127.0.0.1:42"), ("http://127.0.0.1:42", 42))


class RuntimeLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # This suite intentionally requires the integrated server dependencies.
        import aiohttp
        import cryptography
        import tzdata
        cls.shared = tempfile.TemporaryDirectory(prefix="usage fixture environment ")
        cls.template = Path(cls.shared.name) / "environment"
        venv.EnvBuilder(with_pip=False, system_site_packages=True, symlinks=os.name != "nt").create(cls.template)
        if os.name == "nt":
            site_packages = cls.template / "Lib/site-packages"
        else:
            site_packages = cls.template / ("lib/python%d.%d/site-packages" % sys.version_info[:2])
        paths = sorted({str(Path(module.__file__).resolve().parent.parent) for module in (aiohttp, cryptography, tzdata)}
                       | {str(Path(value).resolve()) for value in sys.path if value and "site-packages" in value})
        (site_packages / "usage-test-dependencies.pth").write_text("\n".join(paths) + "\n")

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="usage lifecycle ")
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.package = copy_package(self.parent / "package with spaces")
        self.root = self.parent / "private data with spaces"
        private_directory(self.root)
        private_directory(self.root / "tmp")
        private_directory(self.root / "environments")
        self.seed_environment(runtime.source_stamp(self.package))
        self.addCleanup(self.stop_service)

    def seed_environment(self, stamp):
        name = runtime._environment_name(stamp)
        destination = self.root / "environments" / name
        shutil.copytree(self.template, destination, symlinks=True)
        if os.name == "posix":
            destination.chmod(0o700)
        write_private(destination / "environment.json", encode({"lock_digest": stamp["lock_digest"],
                      "interpreter": runtime._interpreter(), "installed_with": stamp}))
        return destination

    def invoke(self, command, request=None, package=None):
        result = cli(package or self.package, self.root, command, request)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(len(result.stdout.splitlines()), 1)
        parsed = decode(result.stdout)
        self.assertEqual(result.returncode, 0 if parsed["ok"] else 1)
        if (self.root / "local.token").exists():
            self.assertNotIn((self.root / "local.token").read_bytes(), result.stdout)
        self.assertNotIn(str(self.root).encode(), result.stdout)
        return parsed

    def ensure(self, client="window:one", kind="window", package=None):
        return self.invoke("ensure", {"client_id": client, "client_kind": kind}, package)

    def stop_service(self):
        result = cli(self.package, self.root, "stop")
        self.assertEqual(result.stderr, b"")
        self.assertTrue(decode(result.stdout)["ok"], result.stdout)
        self.assertFalse(runtime._running(self.root))

    def test_concurrent_first_starts_one_authenticated_instance_and_fresh_clients(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(self.ensure, client) for client in ("window:one", "host:two")]
            first, second = [future.result(timeout=70) for future in futures]
        self.assertTrue(first["ok"], first)
        self.assertTrue(second["ok"], second)
        self.assertEqual(first["device_id"], second["device_id"])
        self.assertEqual(first["endpoint"], second["endpoint"])
        first_token = (self.root / "local.token").read_bytes()
        launch = decode((self.root / "launch.json").read_bytes())
        self.assertTrue(self.ensure("window:third", "window")["ok"])
        self.assertEqual(first_token, (self.root / "local.token").read_bytes())
        self.assertEqual(launch, decode((self.root / "launch.json").read_bytes()))
        with closing(sqlite3.connect(self.root / "state.sqlite3")) as db:
            clients = {row[0] for row in db.execute("SELECT client_id FROM local_clients")}
        self.assertEqual(clients, {"window:one", "host:two", "window:third"})
        self.assertEqual(self.ensure("setup:fourth", "setup")["error"]["code"], "invalid_request")
        self.assertEqual(self.invoke("doctor")["device_id"], first["device_id"])
        self.assertEqual(list(self.package.rglob("__pycache__")), [])

    def test_stale_pid_metadata_cannot_suppress_a_fresh_daemon(self):
        write_private(self.root / "runtime.json", encode({"pid": os.getpid(), "endpoint": "http://127.0.0.1:1"}))
        result = self.ensure()
        self.assertTrue(result["ok"], result)
        self.assertTrue(runtime._running(self.root))
        self.assertNotEqual(result["endpoint"], "http://127.0.0.1:1")

    def test_interrupted_ensure_recovers_authenticated_ready_candidate(self):
        first = self.ensure()
        self.assertTrue(first["ok"], first)
        launch = decode((self.root / "launch.json").read_bytes())
        token = (self.root / "local.token").read_bytes()
        # This is the durable state left if the launcher exits after ready but
        # before acknowledging/clearing its new-install journal.
        write_private(self.root / "upgrade.json", encode({"phase": "candidate", "launch_id": launch["launch_id"],
                      "backup": None, "previous": None}))
        recovered = self.ensure("window:recovered")
        self.assertTrue(recovered["ok"], recovered)
        self.assertEqual(recovered["device_id"], first["device_id"])
        self.assertEqual(token, (self.root / "local.token").read_bytes())
        self.assertFalse((self.root / "upgrade.json").exists())

    def test_restart_of_the_same_build_takes_no_backup_and_rpc_reports_stopped(self):
        first = self.ensure()
        self.assertTrue(first["ok"], first)
        self.assertEqual(list((self.root / "backups").glob("upgrade-*")), [])
        self.assertTrue(self.invoke("stop")["ok"])
        stopped = self.invoke("rpc", {"operation": "diagnostics", "payload": {}})
        self.assertEqual((stopped["error"]["code"], stopped["state"]), ("companion_unavailable", "stopped"))
        for name in ("one", "two"):
            restarted = self.ensure("window:" + name)
            self.assertTrue(restarted["ok"], restarted)
            self.assertTrue(self.invoke("stop")["ok"])
        self.assertEqual(list((self.root / "backups").glob("upgrade-*")), [])
        self.assertEqual([path.name for path in (self.root / "releases").iterdir()], [first["source_digest"]])
        self.assertFalse((self.root / "upgrade.json").exists())

    def test_restart_preserves_identity_and_rejects_stale_authority(self):
        first = self.ensure()
        self.assertTrue(first["ok"], first)
        old_token = (self.root / "local.token").read_text()
        self.assertTrue(self.invoke("stop")["ok"])
        restarted = self.ensure("window:two")
        self.assertTrue(restarted["ok"], restarted)
        self.assertEqual(first["device_id"], restarted["device_id"])
        self.assertNotEqual(old_token, (self.root / "local.token").read_text())
        _, port = runtime._endpoint(restarted["endpoint"])
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            connection.request("GET", "/health", headers={"Authorization": "Bearer " + old_token})
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            self.assertEqual(decode(response.read())["error"]["code"], "unauthorized")
        finally:
            connection.close()

    def test_health_metadata_identity_and_local_token_are_not_trusted_blindly(self):
        self.assertTrue(self.ensure()["ok"])
        metadata_path = self.root / "runtime.json"
        original = metadata_path.read_bytes()
        metadata = decode(original)
        try:
            write_private(metadata_path, encode(dict(metadata, source_digest="0" * 64)))
            self.assertEqual(self.invoke("doctor")["error"]["code"], "unauthorized")
            write_private(metadata_path, encode(dict(metadata, device_id=str(uuid4()))))
            self.assertEqual(self.invoke("doctor")["error"]["code"], "unauthorized")
            write_private(metadata_path, encode(dict(metadata, endpoint="http://localhost:1234")))
            self.assertEqual(self.invoke("doctor")["error"]["code"], "unauthorized")
        finally:
            write_private(metadata_path, original)
        token = (self.root / "local.token").read_bytes()
        try:
            write_private(self.root / "local.token", b"malformed-secret-sentinel")
            self.assertEqual(self.invoke("doctor")["error"]["code"], "unauthorized")
        finally:
            write_private(self.root / "local.token", token)
        self.assertTrue(self.invoke("doctor")["ok"])

    def test_source_upgrade_uses_immutable_old_release_and_rotates_authority(self):
        first = self.ensure()
        self.assertTrue(first["ok"], first)
        old_release = self.root / "releases" / first["source_digest"]
        original = (old_release / "usage_service/server.py").read_bytes()
        old_token = (self.root / "local.token").read_bytes()
        with (self.package / "usage_service/server.py").open("ab") as stream:
            stream.write(b"\n# Synthetic immutable-release upgrade.\n")
        changed = self.invoke("doctor")
        self.assertEqual(changed["error"]["code"], "incompatible_version")
        self.assertEqual((old_release / "usage_service/server.py").read_bytes(), original)
        second = self.ensure("window:upgraded")
        self.assertTrue(second["ok"], second)
        self.assertNotEqual(first["source_digest"], second["source_digest"])
        self.assertEqual(first["device_id"], second["device_id"])
        self.assertNotEqual(old_token, (self.root / "local.token").read_bytes())
        # A confirmed start drops the upgrade backup and every unreferenced release/environment.
        self.assertEqual([path.name for path in (self.root / "releases").iterdir()], [second["source_digest"]])
        self.assertEqual(len(list((self.root / "environments").iterdir())), 1)
        self.assertEqual(list((self.root / "backups").glob("upgrade-*")), [])
        self.assertFalse((self.root / "upgrade.json").exists())
        rpc = self.invoke("rpc", {"operation": "setup_state", "payload": {}})
        self.assertTrue(rpc["ok"], rpc)

    def test_lock_change_without_consent_keeps_old_instance_alive(self):
        first = self.ensure()
        self.assertTrue(first["ok"], first)
        old_token = (self.root / "local.token").read_bytes()
        with (self.package / "requirements.lock").open("ab") as stream:
            stream.write(b"\n# Synthetic changed lock.\n")
        rejected = self.ensure("window:new-lock")
        self.assertEqual(rejected["state"], "dependency_consent_required")
        self.assertEqual(old_token, (self.root / "local.token").read_bytes())
        self.assertEqual(runtime._health(self.root)["source_digest"], first["source_digest"])
        new_stamp = runtime.source_stamp(self.package)
        self.seed_environment(new_stamp)
        upgraded = self.ensure("window:new-lock")
        self.assertTrue(upgraded["ok"], upgraded)
        self.assertNotEqual(first["lock_digest"], upgraded["lock_digest"])
        self.assertEqual(first["device_id"], upgraded["device_id"])
        self.assertEqual([path.name for path in (self.root / "environments").iterdir()],
                         [runtime._environment_name(new_stamp)])

    def test_failed_upgrade_restores_real_database_identity_and_observation_time(self):
        store = Store(self.root)
        device = store.identity()["device_id"]
        snapshot = {"version": 3, "publisher": "ignored", "as_of_ms": 1234, "readings": [
            {"id": "synthetic-agent", "provider": "openai", "provider_label": "OpenAI", "source_label": "Synthetic",
             "usage_source": "headless", "windows": [{"key": "session", "pool": "all", "used": 75, "remaining": 25, "observed_at_ms": 1200}]}]}
        accepted = store.local_publish("window:fixture", snapshot)
        store.close()
        first = self.ensure()
        self.assertTrue(first["ok"], first)
        old_token = (self.root / "local.token").read_bytes()
        old_package = self.root / "releases" / first["source_digest"]
        # Failure injection: the candidate damages the store while starting, then fails.
        with (self.package / "usage_service/server.py").open("a") as stream:
            stream.write("\n\nimport sys as _sys\n"
                         "import sqlite3 as _sqlite3\n"
                         "from contextlib import closing as _closing\n"
                         "_root = Path(_sys.argv[_sys.argv.index('--data-root') + 1])\n"
                         "with _closing(_sqlite3.connect(_root / 'state.sqlite3')) as _db, _db:\n"
                         "    _db.execute('DELETE FROM snapshots')\n"
                         "    _db.execute('UPDATE installations SET device_id=?', ('00000000-0000-4000-8000-000000000999',))\n"
                         "raise RuntimeError('SECRET-UPGRADE-PATH-SENTINEL')\n")
        failed = self.ensure("window:failed-upgrade")
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["state"], "upgrade_rolled_back")
        self.assertNotIn("SECRET-UPGRADE", json.dumps(failed))
        # Rollback never prunes: the candidate release stays for the next attempt.
        candidate = runtime.source_stamp(self.package)["source_digest"]
        self.assertEqual({path.name for path in (self.root / "releases").iterdir()}, {first["source_digest"], candidate})
        restored = self.invoke("doctor", package=old_package)
        self.assertTrue(restored["ok"], restored)
        self.assertEqual(restored["device_id"], device)
        self.assertEqual(restored["source_digest"], first["source_digest"])
        self.assertEqual(self.invoke("doctor")["error"]["code"], "incompatible_version")
        self.assertNotEqual(old_token, (self.root / "local.token").read_bytes())
        self.assertTrue(self.invoke("stop")["ok"])
        reopened = Store(self.root)
        try:
            self.assertEqual(reopened.identity()["device_id"], device)
            self.assertEqual(reopened.local_records(), [accepted])
            self.assertEqual(reopened.local_records()[0]["snapshot"]["readings"][0]["windows"][0]["observed_at_ms"], 1200)
        finally:
            reopened.close()
        self.assertFalse((self.root / "upgrade.json").exists())
        self.assertEqual(list((self.root / "backups").glob("upgrade-*")), [])

    def test_fresh_start_failure_never_leaves_new_identity(self):
        with (self.package / "usage_service/server.py").open("a") as stream:
            stream.write("\n\nimport sys as _sys\n"
                         "Store(Path(_sys.argv[_sys.argv.index('--data-root') + 1])).close()\n"
                         "raise RuntimeError('SECRET-FRESH-START')\n")
        failed = self.ensure()
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["state"], "start_failed")
        self.assertFalse((self.root / "state.sqlite3").exists())
        self.assertFalse(runtime._running(self.root))
        self.assertFalse((self.root / "local.token").exists())
        self.assertFalse((self.root / "launch.json").exists())

    @unittest.skipUnless(os.name == "posix", "POSIX package mode semantics")
    def test_read_only_package_starts_without_bytecode_or_package_writes(self):
        files = [path for path in self.package.rglob("*") if path.is_file()]
        directories = [self.package] + [path for path in self.package.rglob("*") if path.is_dir()]
        before = {path.relative_to(self.package).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
        try:
            for path in files:
                path.chmod(0o444)
            for path in directories:
                path.chmod(0o555)
            started = self.ensure()
            self.assertTrue(started["ok"], started)
            after = {path.relative_to(self.package).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in self.package.rglob("*") if path.is_file()}
            self.assertEqual(before, after)
        finally:
            for path in directories:
                path.chmod(0o755)
            for path in files:
                path.chmod(0o644)


if __name__ == "__main__":
    unittest.main()
