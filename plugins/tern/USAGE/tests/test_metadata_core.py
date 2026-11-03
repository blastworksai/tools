"""Helper boundary tests; no real credentials, network or provider CLIs are used."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import provider_metadata as core


def request(**extra):
    return {"version": 1, "provider": "kimi", "kind": "kimi", **extra}


class TrustTests(unittest.TestCase):

    def test_request_cannot_select_user_or_profile(self):
        for fields in ({"home": "/another"}, {"user": "root"}, {"env": {"TOKEN": "secret"}},
                       {"command": "TOKEN=secret kimi"}, {"command": "kimi --profile other"},
                       {"version": True}, {"provider": []}, {"kind": "omp"}, {"request_id": "r"},
                       {"model": "claude"}, {"calendars": []}, {"metadata": True}, {"account_id": "a"}):
            with self.subTest(fields=fields), self.assertRaises(core.SafeError):
                core.validate_request(request(**fields))

    def test_usage_projection_is_account_free_and_bounded(self):
        window = {"key": "five_hour", "pool": "default", "used": 25, "remaining": 75,
                  "observed_at_ms": 1000, "resets_at_ms": 2000, "access_token": "keep-local"}
        usage = {"provider": "muse", "windows": [window], "observed_at_ms": 1000,
                 "plan": "Pro", "account": {"token": "keep-local"}, "hint": "keep-local"}
        projected = core.project_usage(usage, {"keep-local"})
        self.assertNotIn("keep-local", json.dumps(projected))
        self.assertEqual(projected["windows"][0]["resets_at_ms"], 2000)
        self.assertEqual(projected["windows"][0]["remaining"], 75)
        for value in (True, float("nan"), float("inf"), -1, 101):
            with self.subTest(value=value), self.assertRaises(core.SafeError):
                core.project_usage({**usage, "windows": [{**window, "used": value}]}, set())
        with self.assertRaises(core.SafeError):
            core.project_usage({**usage, "plan": "keep-local"}, {"keep-local"})

    def test_projection_drops_extra_fields_and_rejects_secret_echo(self):
        metadata = {"principal": "person@example.invalid", "principal_kind": "email", "label": "Person",
                    "plan": "Pro", "workspace_id": "workspace-1", "access_token": "private-token"}
        projected = core.project_metadata(metadata, {"private-token"})
        self.assertNotIn("access_token", projected)
        self.assertEqual(projected["workspace_id"], "workspace-1")
        metadata["label"] = "echo private-token"
        with self.assertRaises(core.SafeError):
            core.project_metadata(metadata, {"private-token"})

    def test_google_cached_email_is_metadata_but_id_token_remains_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            credential = home / "google-auth.json"
            credential.write_text(json.dumps({
                "id_token_email": "person@example.invalid",
                "token": {"id_token": "private-id-token", "access_token": "private-access-token",
                          "refresh_token": "private-refresh-token"},
            }))
            reader = core.SourceIO(home, {})
            reader.read_json(credential)
            self.assertNotIn("person@example.invalid", reader.secrets)
            self.assertTrue({"private-id-token", "private-access-token", "private-refresh-token"} <= reader.secrets)
            metadata = {"principal": "person@example.invalid", "principal_kind": "email",
                        "label": "person@example.invalid"}
            self.assertEqual(core.project_metadata(metadata, reader.secrets), metadata)
            with self.assertRaises(core.SafeError):
                core.project_metadata({**metadata, "label": "private-id-token"}, reader.secrets)

    def test_file_boundaries_size_symlinks_and_secret_tracking(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            home = Path(directory)
            reader = core.SourceIO(home, {})
            credential = home / "auth.json"
            credential.write_text('{"access_token":"keep-local","user_id":"visible-id"}')
            reader.read_json(credential)
            self.assertIn("keep-local", reader.secrets)
            self.assertNotIn("visible-id", reader.secrets)
            target = Path(outside) / "auth.json"
            target.write_text("{}")
            with self.assertRaises(core.SafeError):
                reader.read_json(target)
            if hasattr(os, "symlink"):
                (home / "linked.json").symlink_to(target)
                with self.assertRaises(core.SafeError):
                    reader.read_json(home / "linked.json")
            credential.write_bytes(b"x" * (core.MAX_BYTES + 1))
            with self.assertRaises(core.SafeError):
                reader.read_json(credential)

    def test_http_endpoint_pinning_and_redirect_rejection(self):
        reader = core.SourceIO(Path.home(), {})
        with patch("urllib.request.build_opener") as opener:
            for url in ("http://www.googleapis.com/oauth2/v2/userinfo", "https://www.googleapis.com/oauth2/v2/userinfo?x=1",
                        "https://evil.invalid/me", "https://api.kimi.com/coding/v1/me",
                        "https://api.anthropic.com/api/oauth/profile"):
                with self.assertRaises(core.SafeError):
                    reader.request_json(url, {"Authorization": "Bearer keep-local"})
            with self.assertRaises(core.SafeError):
                reader.request_json("https://www.googleapis.com/oauth2/v2/userinfo", {"anthropic-beta": "oauth-2025-04-20"})
            opener.assert_not_called()
        with self.assertRaises(core.SafeError):
            core.NoRedirect().redirect_request(None, None, 302, "secret", {}, "https://evil.invalid")

    def test_approved_http_get_has_no_proxy_handler_and_bounded_read(self):
        reader = core.SourceIO(Path.home(), {})
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, count):
                self.count = count
                return b'{"user_id":"visible"}'
        response = Response()
        with patch("urllib.request.build_opener") as build:
            build.return_value.open.return_value = response
            value = reader.request_json("https://www.googleapis.com/oauth2/v2/userinfo", {"Authorization": "Bearer keep-local"})
            handlers = build.call_args.args
            self.assertEqual(handlers[0].proxies, {})
            self.assertIsInstance(handlers[1], core.NoRedirect)
            self.assertEqual(build.return_value.open.call_args.args[0].get_method(), "GET")
        self.assertEqual(response.count, core.MAX_BYTES + 1)
        self.assertEqual(value["user_id"], "visible")
        self.assertIn("keep-local", reader.secrets)

    def test_provider_commands_are_exact_and_never_accept_secret_argv(self):
        reader = core.SourceIO(Path.home(), {"PATH": "/usr/bin"})
        for argv in (["claude", "auth", "login"], ["sh", "-c", "anything"],
                     ["claude", "auth", "status", "--json", "keep-local"]):
            with self.assertRaises(core.SafeError):
                reader.run_json(argv)
        with self.assertRaises(core.SafeError):
            reader.run_json(["claude", "auth", "status", "--json"], {"TOKEN": "other"})

    def test_muse_usage_disables_launcher_updates_without_accepting_env_overrides(self):
        env = {"PATH": "/usr/bin", "MUSE_NO_AUTO_UPDATE": "0"}
        reader = core.SourceIO(Path.home(), env)
        with patch.object(core.shutil, "which", return_value="/usr/bin/muse"), \
             patch.object(core, "bounded_process", return_value=b"{}") as process:
            reader.run_json(["muse", "usage", "--json"], env)
        self.assertEqual(process.call_args.args[0], ["/usr/bin/muse", "usage", "--json"])
        self.assertEqual(process.call_args.args[1], {**env, "MUSE_NO_AUTO_UPDATE": "1"})
        self.assertEqual(reader.env, env)
        with self.assertRaises(core.SafeError):
            reader.run_json(["muse", "usage", "--json"], {**env, "MUSE_PROFILE": "other"})

    def test_muse_identity_and_quota_consumers_share_one_request_snapshot(self):
        env = {"PATH": "/usr/bin"}
        reader = core.SourceIO(Path.home(), env)
        command = ["muse", "usage", "--json"]
        with patch.object(core.shutil, "which", return_value="/usr/bin/muse"), \
             patch.object(core, "bounded_process", return_value=b'{"schemaVersion":1,"allowance":null}') as process:
            first = reader.run_json(command, env)
            self.assertIs(reader.run_json(command, env), first)
            self.assertEqual(process.call_count, 1)
            with self.assertRaises(core.SafeError):
                reader.run_json(command, {**env, "MUSE_AUTH_PATH": "/other"})
            core.SourceIO(Path.home(), env).run_json(command, env)
            self.assertEqual(process.call_count, 2)

    def test_muse_failed_snapshot_does_not_implicitly_retry(self):
        reader = core.SourceIO(Path.home(), {})
        with patch.object(core.shutil, "which", return_value="/usr/bin/muse"), \
             patch.object(core, "bounded_process", side_effect=RuntimeError("private-token")) as process:
            for unused in range(2):
                with self.assertRaises(core.SafeError) as raised:
                    reader.run_json(["muse", "usage", "--json"], {})
                self.assertNotIn("private-token", str(raised.exception))
        self.assertEqual(process.call_count, 1)

    def test_obsolete_identity_and_user_transport_are_rejected(self):
        for args in (["--instance-id"], ["--user", "someone"], ["--profile"], []):
            output = io.StringIO()
            with patch.object(core, "current_home") as home, contextlib.redirect_stdout(output):
                core.main(args)
            home.assert_not_called()
            self.assertNotIn("publisher", json.loads(output.getvalue()))
            self.assertEqual(json.loads(output.getvalue())["error"], "Metadata helper arguments are unsupported")

    def test_subprocess_output_is_bounded(self):
        with self.assertRaises(core.SafeError):
            core.bounded_process(
                [sys.executable, "-c", "import sys; sys.stdout.write('x' * (1024 * 1024 + 1))"],
                dict(os.environ),
            )


if __name__ == "__main__":
    unittest.main()
