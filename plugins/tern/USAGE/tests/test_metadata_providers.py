"""Offline metadata tests: synthetic credentials, no CLI execution or network."""

import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "metadata_providers", Path(__file__).resolve().parents[1] / "metadata_providers.py")
providers = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(providers)
HOME = Path("/source/user")
NOW = 1800000000


class FakeIO:
    def __init__(self):
        self.document = {}
        self.status = {"loggedIn": True, "authMethod": "claude.ai",
                       "apiProvider": "firstParty", "email": "person@example.test",
                       "orgId": "organization-7", "orgName": "Example Organization",
                       "subscriptionType": "max"}
        self.reads = []
        self.commands = []
        self.requests = []
        self.payload = {"id": "google-42", "email": "person@example.test", "verified_email": True}

    def read_json(self, path):
        self.reads.append(path)
        if isinstance(self.document, Exception):
            raise self.document
        return self.document

    def run_json(self, argv, env):
        self.commands.append((argv, env.copy()))
        if isinstance(self.status, Exception):
            raise self.status
        return self.status

    def request_json(self, url, headers):
        self.requests.append((url, headers))
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload


class ProviderMetadataTests(unittest.TestCase):
    def collect(self, provider, io, **env):
        kind = {"antigravity": "agy"}.get(provider, provider)
        context = {"HOME": str(HOME), "USAGE_SOURCE_KIND": kind, **env}
        with patch.object(providers.time, "time", return_value=NOW):
            return providers.collect(provider, HOME, context, io)

    def unknown(self, provider, io, **env):
        with self.assertRaises(ValueError) as raised:
            self.collect(provider, io, **env)
        self.assertEqual(str(raised.exception), providers.UNKNOWN)
        self.assertTrue(raised.exception.__suppress_context__)


    def test_claude_projects_cli_status_and_scope_only(self):
        io = FakeIO()
        io.status.update({"access_token": "synthetic-secret", "quota": {"remaining": 42},
                          "configDirectory": str(HOME / ".claude")})
        self.assertEqual(self.collect("claude", io), {
            "principal": "person@example.test", "principal_kind": "email",
            "label": "person@example.test", "organization_id": "organization-7",
            "organization": "Example Organization", "plan": "max"})
        self.assertEqual(io.commands[0][0], ["claude", "auth", "status", "--json"])
        self.assertEqual(io.commands[0][1]["HOME"], str(HOME))
        self.assertEqual(io.reads, [])

    def test_claude_honors_exact_config_context(self):
        io = FakeIO()
        root = str(HOME / "profiles/selected")
        io.status["configDirectory"] = root
        self.collect("claude", io, CLAUDE_CONFIG_DIR=root)
        self.unknown("claude", io)

    def test_claude_null_plan_stays_unknown_not_free(self):
        io = FakeIO()
        io.status.update({"subscriptionType": None, "orgId": None, "orgName": None})
        result = self.collect("claude", io)
        self.assertNotIn("plan", result)
        self.assertNotIn("organization_id", result)

    def test_claude_non_subscription_modes_rejected(self):
        for changes in ({"loggedIn": False}, {"authMethod": "oauth_token"},
                        {"authMethod": "api_key"}, {"apiProvider": "gateway"},
                        {"email": "masked***@example.test"}, {"orgId": []}):
            with self.subTest(changes=changes):
                io = FakeIO()
                io.status.update(changes)
                self.unknown("claude", io)

    def test_antigravity_requests_only_pinned_userinfo(self):
        io = FakeIO()
        io.document = {"token": {"access_token": "synthetic-google-token",
                                 "token_type": "Bearer", "expiry": "2100-01-01T00:00:00Z"},
                       "user_tier": {"name": "unproven-schema-plan"}}
        result = self.collect("antigravity", io)
        self.assertEqual(result, {"principal": "person@example.test", "principal_kind": "email",
                                  "label": "person@example.test"})
        self.assertEqual(io.reads, [HOME / ".gemini/antigravity-cli/antigravity-oauth-token"])
        self.assertEqual(io.requests, [("https://www.googleapis.com/oauth2/v2/userinfo",
                                       {"Authorization": "Bearer synthetic-google-token",
                                        "Accept": "application/json"})])
        self.assertEqual(io.commands, [])

    def test_antigravity_expiry_and_adc_are_never_refreshed(self):
        io = FakeIO()
        io.document = {"token": {"access_token": "synthetic-token", "expiry": "2000-01-01T00:00:00Z"}}
        self.unknown("antigravity", io)
        self.assertEqual(io.requests, [])
        io = FakeIO()
        self.unknown("antigravity", io, AGY_ADC_AUTH="1")
        self.assertEqual(io.reads, [])

    def test_google_stable_subject_fallback_and_unverified_email(self):
        io = FakeIO()
        io.document = {"token": {"access_token": "synthetic-token"}}
        io.payload = {"id": "google-42"}
        self.assertEqual(self.collect("antigravity", io)["principal_kind"], "id")
        io.payload.update({"email": "person@example.test", "verified_email": False})
        self.unknown("antigravity", io)

    def test_muse_projects_cached_metadata_without_key_exchange(self):
        io = FakeIO()
        io.document = {"schema_version": 1, "providers": {"meta": {
            "access_token": "synthetic-token", "api_key": "synthetic-model-key",
            "expires_at": NOW - 600, "user_email": "person@example.test",
            "user_full_name": "Example Person", "subs_active": True,
            "subs_tier_name": "not-a-proven-persisted-field"}}}
        io.status = {"schemaVersion": 1, "allowance": None, "reason": "server_sent_no_usage"}
        result = self.collect("muse", io, XDG_CONFIG_HOME=str(HOME / "selected-config"))
        self.assertEqual(result, {"principal": "person@example.test", "principal_kind": "email",
                                  "label": "Example Person"})
        self.assertEqual(io.reads, [HOME / "selected-config/muse/auth.json"])
        self.assertEqual(io.requests, [])
        self.assertEqual(len(io.commands), 1)
        self.assertEqual(io.commands[0][0], ["muse", "usage", "--json"])
        self.assertEqual(io.commands[0][1]["XDG_CONFIG_HOME"], str(HOME / "selected-config"))
        self.assertNotIn("synthetic-model-key", json.dumps(result))

    def test_muse_future_schema_missing_identity_or_missing_code_key_are_unknown(self):
        for document in ({"schema_version": 99}, {"providers": {"meta": {"api_key": "synthetic"}}},
                         {"providers": {"meta": {"access_token": "synthetic", "expires_at": NOW - 1,
                                                "user_email": "person@example.test"}}}):
            io = FakeIO()
            io.document = document
            self.unknown("muse", io)
            self.assertEqual(io.requests, [])
            self.assertEqual(io.commands, [])

    def test_muse_cached_identity_requires_recognized_cli_profile_response(self):
        for status in ({"schemaVersion": 1, "allowance": None, "reason": "not_signed_in"},
                       {"schemaVersion": 1, "allowance": {}},
                       {"schemaVersion": 2, "allowance": None, "reason": "server_sent_no_usage"},
                       RuntimeError("synthetic-secret failure")):
            io = FakeIO()
            io.document = {"providers": {"meta": {
                "api_key": "synthetic-model-key", "user_email": "person@example.test",
                "access_token": "synthetic-expired-oauth", "expires_at": 0}}}
            io.status = status
            self.unknown("muse", io)
            self.assertEqual(io.requests, [])

    def test_muse_code_key_identity_does_not_require_web_oauth_expiry(self):
        io = FakeIO()
        io.document = {"providers": {"meta": {
            "api_key": "synthetic-model-key", "user_email": "cached@example.test"}}}
        io.status = {"schemaVersion": 1, "allowance": {
            "asOfMs": NOW * 1000, "window": {"usedPercent": 10}},
            "user_email": "not-an-identity-source@example.test"}
        result = self.collect("muse", io)
        self.assertEqual(result["principal"], "cached@example.test")
        self.assertEqual(io.requests, [])

    def test_env_auth_override_never_invokes_cached_login(self):
        for key in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
                    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"):
            with self.subTest(key=key):
                io = FakeIO()
                self.unknown("claude", io, **{key: "synthetic-secret"})
                self.assertEqual(io.reads, [])
                self.assertEqual(io.commands, [])

    def test_providers_read_by_their_own_cli_have_no_metadata_adapter(self):
        for provider in ("openai", "codex", "grok", "kimi", "unrecognized"):
            with self.subTest(provider=provider):
                io = FakeIO()
                self.unknown(provider, io)
                self.assertEqual((io.reads, io.commands, io.requests), ([], [], []))

    def test_wrong_kind_or_other_home_cannot_borrow_cli_identity(self):
        for provider in ("claude", "antigravity", "muse"):
            for context in ({"USAGE_SOURCE_KIND": "omp"}, {"USAGE_SOURCE_KIND": ""},
                            {"HOME": "/different/user"}):
                io = FakeIO()
                self.unknown(provider, io, **context)
                self.assertEqual(io.reads, [])
                self.assertEqual(io.commands, [])

    def test_io_exceptions_never_expose_raw_payload(self):
        io = FakeIO()
        io.status = RuntimeError("synthetic-secret raw response body")
        self.unknown("claude", io)


class MuseUsageTests(unittest.TestCase):
    def collect(self, io, provider="muse", **overrides):
        env = {"HOME": str(HOME), "USAGE_SOURCE_KIND": "muse", **overrides}
        with patch.object(providers.time, "time", return_value=NOW):
            return providers.collect_usage(provider, HOME, env, io)

    def unknown(self, io, **overrides):
        with self.assertRaises(ValueError) as raised:
            self.collect(io, **overrides)
        self.assertEqual(str(raised.exception), providers.USAGE_UNKNOWN)
        self.assertTrue(raised.exception.__suppress_context__)

    def muse_io(self):
        io = FakeIO()
        io.status = {"schemaVersion": 1, "allowance": {
            "tier": "Muse Code High Usage", "asOfMs": (NOW - 300) * 1000,
            "window": {"usedPercent": 12.5, "resetsAtMs": (NOW + 900) * 1000},
            "weekly": {"usedPercent": 75, "resetsAtMs": (NOW + 86400) * 1000}}}
        return io

    def test_success_projects_windows_plan_and_epochs_only(self):
        io = self.muse_io()
        io.status.update({"hint": "ignored", "access_token": "synthetic-secret"})
        result = self.collect(io)
        self.assertEqual(result, {
            "provider": "muse", "plan": "Muse Code High Usage", "observed_at_ms": (NOW - 300) * 1000,
            "windows": [
                {"key": "rolling", "pool": "default", "used": 12.5, "remaining": 87.5,
                 "resets_at_ms": (NOW + 900) * 1000, "observed_at_ms": (NOW - 300) * 1000},
                {"key": "seven_day", "pool": "default", "used": 75, "remaining": 25,
                 "resets_at_ms": (NOW + 86400) * 1000, "observed_at_ms": (NOW - 300) * 1000}]})
        self.assertEqual(io.commands[0][0], ["muse", "usage", "--json"])
        self.assertEqual(io.commands[0][1], {"HOME": str(HOME), "USAGE_SOURCE_KIND": "muse"})
        self.assertEqual(io.reads, [])
        self.assertEqual(io.requests, [])
        self.assertNotIn("secret", json.dumps(result))

    def test_observed_null_allowance_remains_explicitly_unavailable(self):
        io = FakeIO()
        io.status = {"schemaVersion": 1, "allowance": None,
                     "reason": "server_sent_no_usage", "hint": "synthetic-private-detail"}
        self.assertEqual(self.collect(io), {
            "provider": "muse", "windows": [], "observed_at_ms": NOW * 1000,
            "unavailable_reason": "server_sent_no_usage"})

    def test_missing_weekly_is_not_synthesized_and_plan_is_not_inferred(self):
        io = self.muse_io()
        io.status["allowance"]["weekly"] = None
        io.status["allowance"]["tier"] = None
        result = self.collect(io)
        self.assertEqual(len(result["windows"]), 1)
        self.assertNotIn("plan", result)
        io.status["allowance"]["window"] = None
        result = self.collect(io)
        self.assertEqual(result["windows"], [])
        self.assertEqual(result["unavailable_reason"], "unavailable")

    def test_cached_read_does_not_refresh_measurement_time(self):
        io = self.muse_io()
        first = self.collect(io)
        with patch.object(providers.time, "time", return_value=NOW + 600):
            later = providers.collect_usage("muse", HOME, {"HOME": str(HOME), "USAGE_SOURCE_KIND": "muse"}, io)
        self.assertEqual(later["windows"], first["windows"])
        self.assertEqual(later["observed_at_ms"], (NOW - 300) * 1000)

    def test_invalid_or_changed_envelope_is_not_plausible_usage(self):
        for response in ({}, {"schemaVersion": 2, "allowance": {}},
                         {"schemaVersion": True, "allowance": {}},
                         {"schemaVersion": 1}, {"schemaVersion": 1, "allowance": []}):
            io = FakeIO()
            io.status = response
            self.unknown(io)

    def test_invalid_percent_reset_or_plan_is_rejected(self):
        for key, value in (("usedPercent", -1), ("usedPercent", 101), ("usedPercent", True),
                           ("usedPercent", float("nan")), ("usedPercent", float("inf")),
                           ("resetsAtMs", "not-a-date"), ("resetsAtMs", True),
                           ("resetsAtMs", NOW)):
            with self.subTest(key=key, value=value):
                io = self.muse_io()
                io.status["allowance"]["window"][key] = value
                self.unknown(io)
        io = self.muse_io()
        io.status["allowance"]["tier"] = {"unexpected": "value"}
        self.unknown(io)

    def test_reset_absence_is_not_invented_and_measurement_time_is_required(self):
        io = self.muse_io()
        io.status["allowance"]["window"]["resetsAtMs"] = None
        result = self.collect(io)
        self.assertNotIn("resets_at_ms", result["windows"][0])
        self.assertEqual(result["windows"][1]["resets_at_ms"], (NOW + 86400) * 1000)
        for value in (None, True, NOW, "not-a-time"):
            io.status["allowance"]["asOfMs"] = value
            self.unknown(io)

    def test_wrong_source_or_auth_override_never_invokes_the_cli(self):
        for context in ({"provider": "codex"}, {"USAGE_SOURCE_KIND": "omp"},
                        {"HOME": "/different/user"}, {"META_API_KEY": "synthetic-secret"},
                        {"MUSE_AUTH_PATH": "/another/auth.json"}):
            io = self.muse_io()
            self.unknown(io, **context)
            self.assertEqual(io.commands, [])

    def test_cli_failure_does_not_expose_body_or_hint(self):
        io = FakeIO()
        io.status = RuntimeError("synthetic-secret response body")
        self.unknown(io)


if __name__ == "__main__":
    unittest.main()
