"""Provider-read boundary tests: OS identity, code bundle and projection; no real provider traffic."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import provider_metadata as helper
from usage_service import profiles
from usage_service.protocol import ServiceError

OWNER = {"source_uid": "1001", "source_user": "source"}


def metadata(principal="person@example.test", scope="workspace-one"):
    return {"principal": principal, "principal_kind": "email", "label": principal, "workspace_id": scope}


def spec(**extra):
    return {"provider": "openai", "kind": "codex", "label": "Personal", "selectors": {}, "source_uid": "1001", **extra}


class Settings:
    def __init__(self, enabled=True):
        self.enabled = enabled

    def settings(self):
        return {"metadata_enabled": self.enabled}


class AcquireUsageTests(unittest.IsolatedAsyncioTestCase):
    """The live acquisition path, with the helper replaced by a fixed child process."""

    async def acquire(self, output, *, exit_code=0, owner=OWNER, user=None, value=None, store=None):
        launched = []
        real = asyncio.create_subprocess_exec
        script = "import sys; sys.stdin.buffer.read(); sys.stdout.write(sys.argv[1]); sys.exit(int(sys.argv[2]))"
        async def child(*argv, **kwargs):
            launched.append((argv, kwargs))
            return await real(sys.executable, "-c", script, output, str(exit_code), **kwargs)
        with patch.object(profiles, "_target", return_value=(owner, user)), \
             patch.object(profiles.asyncio, "create_subprocess_exec", side_effect=child):
            result = await profiles.acquire_usage(store or Settings(), value or spec())
        return result, launched

    async def assert_code(self, code, output, **kwargs):
        with self.assertRaises(ServiceError) as caught:
            await self.acquire(output, **kwargs)
        self.assertEqual(caught.exception.code, code)
        self.assertNotIn("sentinel", json.dumps(caught.exception.public()))

    async def test_projects_metadata_and_usage_and_sends_only_the_fixed_request(self):
        usage = {"provider": "openai", "observed_at_ms": 1800000000000, "credential": "secret-sentinel",
                 "windows": [{"key": "seven_day", "pool": "default", "used": 8, "remaining": 92,
                              "observed_at_ms": 1800000000000}]}
        output = json.dumps({"version": 1, **OWNER, "raw": "secret-sentinel",
                             "metadata": {**metadata(), "access_token": "secret-sentinel"}, "usage": usage})
        result, launched = await self.acquire(output)
        self.assertEqual(result["metadata"], metadata())
        self.assertEqual(result["usage"]["windows"][0]["used"], 8)
        self.assertEqual(set(result), {"version", "metadata", "usage"})
        self.assertNotIn("sentinel", json.dumps(result))
        argv, kwargs = launched[0]
        self.assertEqual(argv[-1], "--headless")
        self.assertEqual(Path(argv[-2]).name, "provider_metadata.py")
        self.assertNotIn("sudo", json.dumps(argv))
        self.assertNotIn("HOME", kwargs["env"])

    async def test_cross_user_read_runs_the_verified_bundle_through_noninteractive_sudo(self):
        output = json.dumps({"version": 1, **OWNER, "error": "local_login_unavailable"})
        result, launched = await self.acquire(output, user="source")
        self.assertEqual(result["error"], "local_login_unavailable")
        argv, kwargs = launched[0]
        self.assertEqual(argv[:6], ("/usr/bin/sudo", "-n", "-u", "source", "--", argv[5]))
        self.assertTrue(argv[-2].startswith("/tmp/usage-helper-"))
        self.assertEqual(kwargs["env"], {"PATH": "/usr/local/bin:" + os.defpath, "LANG": "C.UTF-8"})
        self.assertFalse(Path(argv[-2]).parent.exists())

    async def test_wrong_executed_identity_is_a_context_mismatch(self):
        output = json.dumps({"version": 1, "source_uid": "2002", "source_user": "source",
                             "metadata": metadata()})
        await self.assert_code("source_context_ambiguous", output)
        await self.assert_code("source_context_ambiguous", output, value=spec(source_uid="2002"))

    async def test_raw_and_unknown_errors_never_return(self):
        for value in ({"version": 1, **OWNER, "error": "private-secret-path-sentinel"},
                      {"version": 1, **OWNER, "error": "Source provider command is unavailable"}):
            with self.subTest(value=value):
                result, _ = await self.acquire(json.dumps(value))
                self.assertEqual(result, {"version": 1, "error": "source_usage_unavailable"})
        for code in sorted(profiles.ERRORS):
            with self.subTest(code=code):
                result, _ = await self.acquire(json.dumps({"version": 1, **OWNER, "error": code}))
                self.assertEqual(result["error"], code)

    async def test_helper_failures_before_identity_are_unavailable_not_mismatched(self):
        await self.assert_code("source_usage_unavailable",
                               json.dumps({"version": 1, "error": "Metadata request version is unsupported"}))
        await self.assert_code("source_usage_unavailable", "not json sentinel")
        await self.assert_code("source_usage_unavailable", json.dumps({"version": 1, **OWNER}), exit_code=1)
        await self.assert_code("source_usage_unavailable", json.dumps({"version": 1, **OWNER,
            "metadata": {**metadata(), "label": "/private/path-sentinel"}}))
        await self.assert_code("source_usage_unavailable", json.dumps({"version": 1, **OWNER,
            "usage": {"provider": "openai", "observed_at_ms": 1, "windows": [{"key": "k", "pool": "p", "used": 101,
                      "remaining": -1, "observed_at_ms": 1}]}}))

    async def test_consent_is_checked_before_any_process(self):
        with patch.object(profiles.asyncio, "create_subprocess_exec") as launch, self.assertRaises(ServiceError) as caught:
            await profiles.acquire_usage(Settings(False), spec())
        self.assertEqual(caught.exception.code, "source_metadata_disabled")
        launch.assert_not_called()

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux helper boundary")
    async def test_real_helper_reports_an_expired_claude_login_without_any_request(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
                "accessToken": "secret-sentinel", "expiresAt": int(time.time() * 1000) - 1}}))
            result = await profiles.acquire_usage(Settings(), {"provider": "claude", "kind": "claude", "label": "Work",
                "selectors": {"CLAUDE_CONFIG_DIR": directory}, "source_uid": helper.source_identity()["source_uid"]})
        self.assertEqual(result, {"version": 1, "error": "web_login_expired"})


class HelperBoundaryTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "Linux cross-user code staging")
    def test_cross_user_bundle_is_immutable_code_only_and_removed_after_failure(self):
        with profiles._helper_bundle("mapped") as bundle:
            self.assertEqual({path.relative_to(bundle).as_posix() for path in bundle.rglob("*.py")}, set(profiles.BUNDLE))
            self.assertEqual(bundle.stat().st_mode & 0o777, 0o755)
            for name in profiles.BUNDLE:
                self.assertEqual((bundle / name).stat().st_mode & 0o777, 0o644)
            self.assertEqual(profiles._verified_bundle(str(bundle)), bundle)
            (bundle / "metadata_providers.py").write_bytes(b"changed")
            with self.assertRaises(ServiceError):
                profiles._verified_bundle(str(bundle))
        self.assertFalse(bundle.exists())
        failed_bundle = None
        with self.assertRaises(RuntimeError):
            with profiles._helper_bundle("mapped") as failed_bundle:
                raise RuntimeError("synthetic execution failure")
        self.assertFalse(failed_bundle.exists())

    def test_cross_user_mac_windows_and_root_linux_are_rejected_before_execution(self):
        for platform, owner in (("darwin", {"source_uid": "501", "source_user": "current"}),
                                ("win32", {"source_uid": "S-1-5-21-1001"})):
            with patch.object(profiles.sys, "platform", platform), patch.object(helper, "source_identity", return_value=owner):
                self.assertEqual(profiles._target(owner["source_uid"]), (owner, None))
                with self.assertRaises(ServiceError) as caught:
                    profiles._target("another")
                self.assertEqual(caught.exception.code, "forbidden")
        if os.name == "posix":
            with patch.object(profiles.sys, "platform", "linux"), \
                 patch.object(helper, "source_identity", return_value={"source_uid": "1001", "source_user": "current"}), \
                 patch("pwd.getpwnam", return_value=SimpleNamespace(pw_uid=0, pw_name="root")):
                with self.assertRaises(ServiceError) as caught:
                    profiles._target("root")
                self.assertEqual(caught.exception.code, "forbidden")

    def test_changed_public_bundle_is_rejected_before_any_process(self):
        real_read = Path.read_bytes
        root = Path(profiles.__file__).resolve().parents[1]
        # A distinct candidate directory lets this test exercise digest matching,
        # independent of the host fixture directory's OS permission strategy.
        with tempfile.TemporaryDirectory() as directory:
            public = Path(directory)
            for name in profiles.BUNDLE:
                (public / name).parent.mkdir(parents=True, exist_ok=True)
                (public / name).write_bytes(real_read(root / name))
            def info(path, *args, **kwargs):
                mode = 0o100644 if path.suffix == ".py" else 0o40755
                return SimpleNamespace(st_uid=0, st_mode=mode, st_size=20000)
            with patch.object(Path, "stat", info), patch.object(Path, "lstat", info), \
                 patch.object(Path, "resolve", lambda path, **kwargs: path):
                self.assertEqual(profiles._verified_bundle(str(public)), public)
                (public / "metadata_providers.py").write_bytes(b"changed")
                with self.assertRaises(ServiceError) as caught:
                    profiles._verified_bundle(str(public))
                self.assertEqual(caught.exception.code, "source_helper_unverified")

    def test_metadata_projection_drops_unknown_fields_and_rejects_path_identity(self):
        projected = profiles._metadata({**metadata(), "access_token": "secret-sentinel"})
        self.assertEqual(projected, metadata())
        for label in ("/private/path", "C:\\private", "https://private.invalid"):
            with self.subTest(label=label), self.assertRaises(helper.SafeError):
                profiles._metadata({**metadata(), "label": label})

    def test_windows_profile_sid_and_file_sid_must_both_match_current_token(self):
        class WindowsOS:
            name = "nt"
            def __getattr__(self, name):
                return getattr(os, name)
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            selected = home / "selected"
            selected.mkdir()
            credential = selected / "auth.json"
            credential.write_text('{"account":"visible"}')
            with patch.object(helper, "os", WindowsOS()), \
                 patch.object(helper, "windows_sid", return_value="S-1-5-21-1001"):
                context = helper.profile_environment("codex", home, {"CODEX_HOME": str(selected)})
                self.assertEqual(context["USERPROFILE"], str(home))
                self.assertEqual(helper.SourceIO(home, context).read_json(credential), {"account": "visible"})
            with patch.object(helper, "os", WindowsOS()), \
                 patch.object(helper, "windows_sid", side_effect=lambda path=None: "S-1-5-21-2002" if path else "S-1-5-21-1001"):
                with self.assertRaises(helper.SafeError):
                    helper.profile_environment("codex", home, {"CODEX_HOME": str(selected)})
                with self.assertRaises(helper.SafeError):
                    helper.SourceIO(home, {"CODEX_HOME": str(selected)}).read_json(credential)

    @unittest.skipUnless(os.name == "posix", "Unix profile UID boundary")
    def test_unix_selected_directory_owner_is_not_authorized_by_path(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            selected = home / "selected"
            selected.mkdir()
            with patch.object(helper.os, "geteuid", return_value=os.geteuid() + 1):
                with self.assertRaises(helper.SafeError):
                    helper.profile_environment("codex", home, {"CODEX_HOME": str(selected)})


if __name__ == "__main__":
    unittest.main()
