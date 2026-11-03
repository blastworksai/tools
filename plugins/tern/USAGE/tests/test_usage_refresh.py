"""Single-flight refresh, immutable configuration, cadence and narrow transport."""
import asyncio
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch

from usage_service import profiles
from usage_service.protocol import ServiceError
from usage_service.refresh import Refresh
from usage_service.server import Companion
from usage_service.store import Store
from usage_service import spawn_roster


def definition(index, provider="Claude", **extra):
    return {"id": "account-" + str(index), "provider": provider, "account_label": "Account " + str(index),
            "backend": "local-terminal", "user": "fixture", **extra}


def response(provider="claude", used=8):
    return {"version": 1, "metadata": {"principal": "a@example.test", "principal_kind": "email", "label": "a@example.test"},
            "usage": {"provider": provider, "observed_at_ms": 1800000000123, "windows": [
                {"key": "seven_day", "pool": "default", "used": used, "remaining": 100-used, "observed_at_ms": 1800000000123}]}}


class RefreshTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "plugin-data" / "usage" / "companion"
        self.root.mkdir(mode=0o700, parents=True)
        self.store = Store(self.root)
        self.store.configure({"metadata_enabled": True})
        self.refresh = Refresh(self.store, self.root)
        self.refresh.path.parent.mkdir(parents=True)
        self.save([definition(1)])
        self.identity = patch.object(spawn_roster, "source_identity", return_value={"source_uid": "1000", "source_user": "fixture"})
        self.identity.start()
        self.acquire = AsyncMock(return_value=response())
        self.acquiring = patch.object(profiles, "acquire_usage", self.acquire)
        self.acquiring.start()

    async def asyncTearDown(self):
        await self.refresh.close()
        self.acquiring.stop()
        self.identity.stop()
        self.store.close()
        self.temp.cleanup()

    def save(self, definitions, stale=None):
        # SPAWN's live roster is its `authority` key; `config` is its stale original.
        value = {"authority": {"version": 3, "namespace": "host-fixture", "next_authority": 1,
            "host_key": "host:fixture-device", "config_revision": 0, "sessions": {}, "reviewed_sources": {},
            "config": {"schema": 2, "hosts": {"host:fixture-device": {"schema": 2, "agents": definitions}}}}}
        if stale is not None:
            value["config"] = {"schema": 2, "hosts": {"host:fixture-device": {"schema": 2, "agents": stale}}}
        self.refresh.path.write_text(json.dumps(value))

    def specs(self):
        return [call.args[1] for call in self.acquire.call_args_list]

    def spec_error(self, **extra):
        self.save([definition(1, **extra)])
        with self.assertRaises(ServiceError) as caught:
            self.refresh._spec(self.refresh.configuration()[3][0])
        return caught.exception.code

    async def test_all_definitions_without_enrollment_and_status_never_acquires(self):
        kinds = ["Claude", "Codex", "Agy", "Grok", "Kimi", "Muse", "Claude", "Codex", "Agy", "Kimi", "Muse"]
        self.save([definition(i, kind) for i, kind in enumerate(kinds)] + [definition(99, "OMP")])
        self.assertEqual(self.refresh.preferences({}), {"refresh_interval_seconds": 0})
        self.assertEqual(len(self.refresh.results()["items"]), 11)
        self.refresh.status()
        self.acquire.assert_not_called()
        started = self.refresh.request()
        self.assertEqual((started["state"], started["total"]), ("running", 11))
        await self.refresh.job
        self.assertEqual(self.acquire.await_count, 6)
        self.assertEqual(self.refresh.status()["completed"], 11)
        self.assertEqual({spec["kind"] for spec in self.specs()}, {"claude", "codex", "agy", "grok", "kimi", "muse"})
        self.assertTrue(all(call.args[0] is self.store for call in self.acquire.call_args_list))
        exported = json.dumps(self.refresh.results())
        self.assertNotIn("source_uid", exported)
        self.assertNotIn('"user"', exported)
        self.assertNotIn('"selectors"', exported)

    async def test_requests_coalesce_and_workers_are_bounded(self):
        self.save([definition(index, command="claude", arguments=["--config-dir", "/profiles/" + str(index)])
                   for index in range(11)])
        gate, two_started = asyncio.Event(), asyncio.Event()
        active, peak = 0, 0
        async def acquire(_store, _spec):
            nonlocal active, peak
            active += 1
            peak = max(peak, active)
            if active == 2:
                two_started.set()
            try:
                await gate.wait()
                return response()
            finally:
                active -= 1
        self.acquire.side_effect = acquire
        initial = self.refresh.request()
        job = self.refresh.job
        await two_started.wait()
        for _ in range(5):
            self.assertEqual(self.refresh.request()["requested_at_ms"], initial["requested_at_ms"])
            self.assertIs(self.refresh.job, job)
        gate.set()
        await job
        self.assertEqual(peak, 2)
        self.assertEqual(self.acquire.await_count, 11)
        self.assertEqual(self.refresh.status()["state"], "idle")

    async def test_config_change_discards_completed_job_and_removed_account(self):
        gate, started = asyncio.Event(), asyncio.Event()
        async def acquire(_store, _spec):
            started.set()
            await gate.wait()
            return response()
        self.acquire.side_effect = acquire
        self.refresh.request()
        await started.wait()
        self.save([definition(2)])
        gate.set()
        await self.refresh.job
        self.assertEqual(self.refresh.status()["failures"], [{"code": "source_configuration_changed"}])
        self.assertIsNone(self.store.local_state("usage_results"))
        self.assertEqual([item["id"] for item in self.refresh.results()["items"]], ["account-2"])

    async def test_no_login_is_explicit_and_raw_failure_is_private(self):
        self.acquire.side_effect = ServiceError("local_login_unavailable")
        self.refresh.request()
        await self.refresh.job
        self.assertEqual(self.refresh.status()["failures"], [{"account": "account-1", "code": "local_login_unavailable"}])
        self.assertEqual(self.refresh.results()["items"][0]["response"]["error"], "local_login_unavailable")
        self.acquire.side_effect = ValueError("private/path?token=SECRET")
        self.refresh.request()
        await self.refresh.job
        self.assertNotIn("SECRET", json.dumps(self.refresh.results()))

    async def test_consent_blocks_manual_and_periodic_acquisition(self):
        self.store.configure({"metadata_enabled": False})
        with self.assertRaises(ServiceError) as caught:
            self.refresh.request()
        self.assertEqual(caught.exception.code, "source_metadata_disabled")
        self.refresh.preferences({"refresh_interval_seconds": 60})
        await self.refresh.start()
        await asyncio.sleep(0)
        self.acquire.assert_not_called()
        self.assertEqual(self.refresh.results()["items"][0]["response"]["error"], "source_metadata_disabled")

    async def test_preferences_persist_and_manual_default_never_launches(self):
        await self.refresh.start()
        await asyncio.sleep(0)
        self.acquire.assert_not_called()
        for bad in (True, 1, 59, 60.5, "60", 86401, -1):
            with self.subTest(bad=bad), self.assertRaises(ServiceError):
                self.refresh.preferences({"refresh_interval_seconds": bad})
        self.refresh.preferences({"refresh_interval_seconds": 120})
        reopened = Refresh(self.store, self.root)
        self.assertEqual(reopened.preferences({})["refresh_interval_seconds"], 120)
        self.refresh.preferences({"refresh_interval_seconds": 0})
        self.assertEqual(reopened.preferences({})["refresh_interval_seconds"], 0)
        await reopened.close()

    async def test_persisted_cadence_requests_once_when_due(self):
        self.refresh.preferences({"refresh_interval_seconds": 60})
        self.refresh.progress["last_completed_ms"] = int((time.time() - 61) * 1000)
        called = asyncio.Event()
        async def acquire(_store, _spec):
            called.set()
            return response()
        self.acquire.side_effect = acquire
        await self.refresh.start()
        await asyncio.wait_for(called.wait(), timeout=2)
        await self.refresh.job
        self.assertEqual(self.acquire.await_count, 1)
        self.refresh.preferences({"refresh_interval_seconds": 0})

    async def test_close_cancels_owned_workers(self):
        started, cancelled = asyncio.Event(), asyncio.Event()
        async def acquire(_store, _spec):
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()
        self.acquire.side_effect = acquire
        self.refresh.request()
        await started.wait()
        await self.refresh.close()
        self.assertTrue(cancelled.is_set())
        self.assertTrue(self.refresh.job.done())

    async def test_source_publication_is_revision_fenced(self):
        result = self.refresh.results()
        snapshot = {"version": 3, "publisher": "fixture", "as_of_ms": 1800000000000,
                    "readings": [], "roster": result["roster"]}
        self.assertEqual(self.refresh.publish({"token": result["token"], "snapshot": snapshot}), {"accepted": True})
        self.assertEqual(self.refresh.results()["published_token"], result["token"])
        self.save([])
        with self.assertRaises(ServiceError) as caught:
            self.refresh.publish({"token": result["token"], "snapshot": snapshot})
        self.assertEqual(caught.exception.code, "source_configuration_changed")
        self.assertEqual(self.refresh.results()["items"], [])

    async def test_pre_2_0_saved_results_are_served_as_usage(self):
        item = self.refresh.configuration()[3][0]
        legacy = response()
        legacy["native_usage"] = legacy.pop("usage")
        legacy["resets"] = []
        saved = {key: item[key] for key in ("scope_id", "id", "provider", "label", "revision")}
        self.store.set_local_state("usage_results", {"revision": "pre-2.0", "completed_at_ms": 1,
                                                     "items": [dict(saved, response=legacy)]})
        served = self.refresh.results()["items"][0]["response"]
        self.assertEqual(served, response())
        self.assertEqual(self.store.local_state("usage_results")["items"][0]["response"], legacy)

    async def test_changed_definition_does_not_reuse_an_old_response(self):
        self.refresh.request()
        await self.refresh.job
        self.save([definition(1, account_label="Changed")])
        value = self.refresh.results()["items"][0]
        self.assertEqual(value["response"]["error"], "not_yet_measured")

    async def test_member_rejects_selectors_and_source_only_operations(self):
        # Exercise the actual dispatcher, not a second test router.
        companion = object.__new__(Companion)
        companion.store = self.store
        companion.refresh = self.refresh
        companion.sync = type("Sync", (), {"usage_operation": AsyncMock(return_value={"state": "running"})})()
        self.store.configure({"role": "member"})
        for operation in ("usage_refresh", "usage_status"):
            with self.assertRaises(ServiceError):
                await companion.usage_operation(operation, {"command": "not-allowed"})
        with self.assertRaises(ServiceError):
            await companion.usage_operation("usage_results", {})


    async def test_spawns_user_wrapper_preserves_account_and_inline_selectors(self):
        self.save([definition(1, command="sudo -u fixture -H -- claude --config-dir /account-home")])
        spec = self.refresh._spec(self.refresh.configuration()[3][0])
        self.assertEqual((spec["provider"], spec["source_uid"], spec["user"]), ("claude", "1000", "fixture"))
        self.assertEqual(spec["selectors"], {"CLAUDE_CONFIG_DIR": "/account-home"})
        self.assertEqual(self.spec_error(command="sudo -u another-account -H -- claude"), "source_context_ambiguous")

    async def test_continue_and_model_settings_do_not_change_account_context(self):
        for provider, command, arguments in (
            ("Claude", "claude", ["-c"]),
            ("Codex", "codex", ["-c", 'model_reasoning_effort="high"']),
        ):
            self.save([definition(1, provider, command=command, arguments=arguments)])
            spec = self.refresh._spec(self.refresh.configuration()[3][0])
            self.assertEqual((spec["source_uid"], spec["selectors"]), ("1000", {}))
        for key in ("model_provider", "cli_auth_credentials_store", "forced_chatgpt_workspace_id"):
            self.assertEqual(self.spec_error(provider="Codex", command="codex", arguments=["-c", key + "=changed"]),
                             "source_context_ambiguous")

    async def test_profile_and_config_file_flags_are_never_read_as_the_default_context(self):
        for provider, command, arguments in (
            ("Codex", "codex", ["-p", "work"]),
            ("Codex", "codex", ["--profile=work"]),
            ("Claude", "claude", ["--settings", "/settings.json"]),
            ("Claude", "claude", ["--settings-file", "/settings.json"]),
            ("Kimi", "kimi", ["--config-file", "/kimi.toml"]),
            ("Grok", "grok", ["--home", "/grok-home"]),
            ("Muse", "muse", ["--agent-dir=/agent"]),
            ("Codex", "codex", ["--config", "model_provider=other"]),
            ("Kimi", "kimi", ["--api-key", "secret"]),
            ("Claude", "claude", ["--base-url", "https://proxy.invalid"]),
            ("Grok", "grok", ["-c", "anything"]),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.spec_error(provider=provider, command=command, arguments=arguments),
                                 "source_context_ambiguous")
        # -p is Claude's print mode, not a profile.
        self.save([definition(1, command="claude", arguments=["-p", "hello"])])
        self.assertEqual(self.refresh._spec(self.refresh.configuration()[3][0])["selectors"], {})

    async def test_spawn_selector_is_the_only_profile_source(self):
        self.refresh.request()
        await self.refresh.job
        self.assertEqual(self.specs()[-1]["selectors"], {})
        self.save([definition(1, command="claude", arguments=["--config-dir", "/spawn-selected"])])
        self.refresh.request()
        await self.refresh.job
        self.assertEqual(self.specs()[-1]["selectors"], {"CLAUDE_CONFIG_DIR": "/spawn-selected"})

    async def test_environment_fields_fail_closed(self):
        for field in ("env", "environment"):
            for value in ({"CLAUDE_CONFIG_DIR": "/selected"}, {}, "corrupt"):
                with self.subTest(field=field, value=value):
                    self.assertEqual(self.spec_error(**{field: value}), "source_context_ambiguous")

    async def test_ssh_records_are_never_read_on_this_machine(self):
        for user in ("fixture", "", None):
            with self.subTest(user=user):
                remote = definition(2, backend="ssh-command", host="gpu.example.invalid", user=user)
                self.save([definition(1), remote])
                self.acquire.reset_mock()
                self.refresh.request()
                await self.refresh.job
                self.assertEqual(self.acquire.await_count, 1)
                self.assertNotIn("gpu.example.invalid", json.dumps(self.specs()))
                items = {item["id"]: item["response"] for item in self.refresh.results()["items"]}
                self.assertEqual(items["account-2"], {"version": 1, "error": "source_remote"})
                self.assertIn("usage", items["account-1"])
                self.assertIn({"account": "account-2", "code": "source_remote"}, self.refresh.status()["failures"])

    async def test_unknown_spawn_user_is_an_invalid_profile(self):
        with patch.object(spawn_roster, "_uid", return_value=None):
            self.assertEqual(self.spec_error(user="no-such-user"), "source_profile_invalid")

    async def test_same_context_is_read_once_whatever_the_user_spelling(self):
        self.save([definition(1, "Kimi", user=""), definition(2, "Kimi", user="fixture"),
                   definition(3, "Kimi", user="1000")])
        self.refresh.request()
        await self.refresh.job
        self.assertEqual(self.acquire.await_count, 1)
        self.assertEqual(self.refresh.status()["completed"], 3)
        self.assertEqual(len(self.refresh.results()["items"]), 3)

    async def test_stale_spawn_config_never_replaces_the_authority_roster(self):
        self.save([definition(1, account_label="Current")], stale=[definition(7, "Codex"), definition(8, "Muse")])
        self.assertEqual([(item["id"], item["label"]) for item in self.refresh.results()["items"]],
                         [("account-1", "Current")])
        self.refresh.request()
        await self.refresh.job
        self.assertEqual([spec["kind"] for spec in self.specs()], ["claude"])

    async def test_job_uses_frozen_selectors_and_never_exports_commands(self):
        self.save([definition(index, command="claude", arguments=["--config-dir", "/frozen"]) for index in range(3)])
        entered, gate = asyncio.Event(), asyncio.Event()
        async def acquire(_store, _spec):
            entered.set()
            await gate.wait()
            return response()
        self.acquire.side_effect = acquire
        self.refresh.request()
        await entered.wait()
        self.save([definition(index, command="claude", arguments=["--config-dir", "/changed"]) for index in range(3)])
        gate.set()
        await self.refresh.job
        self.assertTrue(all(spec["selectors"] == {"CLAUDE_CONFIG_DIR": "/frozen"} for spec in self.specs()))
        self.assertEqual(self.refresh.status()["failures"], [{"code": "source_configuration_changed"}])
        self.assertNotIn("/frozen", json.dumps(self.refresh.results()))


if __name__ == "__main__":
    unittest.main()
