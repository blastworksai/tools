"""Provider protocol projection without live logins or model turns."""
import json
from pathlib import Path
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import provider_metadata as helper
from usage_service import readers
from usage_service.protocol import ServiceError, validate_snapshot

AT = 1800000000123


class ParsingTests(unittest.TestCase):
    def test_claude_preserves_scoped_windows_fractional_reset_and_zero(self):
        windows = readers.parse_claude({"five_hour": {"utilization": 0, "resets_at": "2026-11-04T06:37:47.123Z"},
            "seven_day_sonnet": {"utilization": 12.5}, "seven_day_opus": {"utilization": None}}, AT)
        self.assertEqual([(w["key"], w["pool"]) for w in windows],
                         [("five_hour", "default"), ("seven_day", "sonnet"), ("seven_day", "opus")])
        self.assertEqual(windows[0]["used"], 0)
        self.assertEqual(windows[0]["resets_at_ms"] % 1000, 123)
        self.assertEqual(windows[2]["unavailable_reason"], "not_reported")
        self.assertNotIn("used", windows[2])

    def test_codex_named_map_wins_and_duration_never_guessed(self):
        windows = readers.parse_codex({"rateLimits": {"primary": {"usedPercent": 99}},
            "rateLimitsByLimitId": {"map-alias": {"limitId": "codex", "primary": {
                "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1800000010.123}},
                "review": {"primary": {"usedPercent": 2, "windowDurationMins": 17},
                           "secondary": {"usedPercent": True}}}}, AT)
        self.assertEqual(len(windows), 3)
        self.assertEqual(windows[0]["key"], "seven_day")
        self.assertEqual(windows[0]["pool"], "codex")
        self.assertEqual(windows[0]["window_duration_mins"], 10080)
        self.assertEqual(windows[0]["resets_at_ms"], 1800000010123)
        self.assertEqual(windows[1]["key"], "primary:17m")
        self.assertEqual(windows[2]["key"], "secondary")
        self.assertEqual(windows[2]["unavailable_reason"], "unparsed")

    def test_codex_credit_balance_is_account_level_and_survives_projection(self):
        for balance in ("0", "12.5", "9007199254740991"):
            with self.subTest(balance=balance):
                quota = {"rateLimits": {"credits": {
                    "hasCredits": balance != "0", "unlimited": False, "balance": balance}},
                    "rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 25},
                        "credits": {"hasCredits": True, "unlimited": False, "balance": "999"}}}}
                with patch.object(readers, "rpc", return_value=(
                        {"account": {"type": "chatgpt", "email": "fixture@example.test"}}, quota)):
                    _, usage = readers.collect("openai", Path("/source"), {}, None)
                projected = helper.project_usage(usage, set())
                self.assertEqual(projected["credit_balance"], float(balance))
                self.assertEqual(len(projected["windows"]), 1)
                self.assertNotIn("credit_balance", projected["windows"][0])

    def test_codex_credit_balance_never_guesses_missing_or_unlimited_amounts(self):
        for credits in (None, {}, {"hasCredits": True, "unlimited": True, "balance": "10"},
                        {"hasCredits": True, "balance": "10"},
                        *({"hasCredits": True, "unlimited": False, "balance": value}
                          for value in (None, True, 12, "-1", "NaN", "Infinity", "1e3",
                                        "9007199254740992", "12 credits", ""))):
            with self.subTest(credits=credits):
                quota = {"rateLimits": {"credits": credits}, "rateLimitsByLimitId": {
                    "arbitrary": {"credits": {"hasCredits": True, "unlimited": False, "balance": "99"}}}}
                with patch.object(readers, "rpc", return_value=(
                        {"account": {"type": "chatgpt", "email": "fixture@example.test"}}, quota)):
                    _, usage = readers.collect("openai", Path("/source"), {}, None)
                self.assertNotIn("credit_balance", usage)

    def test_credit_balance_snapshot_round_trip_and_numeric_bounds(self):
        reading = {"id": "r", "provider": "openai", "provider_label": "OpenAI",
                   "source_label": "Source", "usage_source": "headless", "windows": []}
        for balance in (0, 12.5, 9_007_199_254_740_991):
            with self.subTest(balance=balance):
                snapshot = {"version": 3, "publisher": "source", "as_of_ms": AT,
                            "readings": [dict(reading, credit_balance=balance)]}
                self.assertEqual(validate_snapshot(snapshot)["readings"][0]["credit_balance"], balance)
        snapshot["readings"] = [reading]
        self.assertNotIn("credit_balance", validate_snapshot(snapshot)["readings"][0])
        for balance in (True, -1, "12", float("nan"), float("inf"), 9_007_199_254_740_992):
            with self.subTest(balance=balance):
                snapshot["readings"] = [dict(reading, credit_balance=balance)]
                with self.assertRaises(ServiceError):
                    validate_snapshot(snapshot)
                with self.assertRaises(helper.SafeError):
                    helper.project_usage({"provider": "openai", "windows": [],
                        "observed_at_ms": AT, "credit_balance": balance}, set())

    def test_agy_two_pools_and_remaining_direction(self):
        windows = readers.parse_agy("banner\nGemini Models\tWeekly Limit Remaining\t100%\t2026-11-04T00:00:00Z\n"
            "Claude and GPT models\tWeekly Limit Remaining\t16%\t2026-11-05T00:00:00Z\n"
            "Claude and GPT models\tFive Hour Limit Remaining\t?\t\n"
            "New Pool\tWeekly Limit Remaining\t10%\t\n", AT)
        self.assertEqual([(w["pool"], w.get("used")) for w in windows], [("gemini", 0), ("claude_gpt", 84), ("claude_gpt", None)])
        self.assertEqual(windows[1]["remaining"], 16)
        self.assertEqual(windows[2]["unavailable_reason"], "unparsed")

    def test_grok_billing_is_used_and_exact_reset(self):
        value = readers.parse_grok({"config": {"creditUsagePercent": 28, "currentPeriod": {
            "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-11-04T13:30:39.009Z"}}}, AT)[0]
        self.assertEqual((value["key"], value["used"], value["remaining"]), ("seven_day", 28, 72))
        self.assertEqual(value["resets_at_ms"] % 1000, 9)

    def test_kimi_ratios_are_vendor_reports_including_all_zero(self):
        value = readers.parse_kimi({"data": {"quota": {"usages": {
            "limit5h": {"usedRatio": 0, "resetTime": "2026-11-03T03:02:38Z"},
            "limit7d": {"usedRatio": .0009, "resetTime": "2026-11-07T14:02:38Z"}}}}}, AT)
        self.assertEqual(value[0]["used"], 0)
        self.assertAlmostEqual(value[1]["used"], .09)
        self.assertIsNotNone(value[1]["resets_at_ms"])
        self.assertEqual(readers.parse_kimi({"usages": {"limit5h": {"used_ratio": 0}}}, AT)[0]["used"], 0)
        self.assertNotIn("used", readers.parse_kimi({"usages": {"limit5h": {"used_ratio": 50}}}, AT)[0])
        with self.assertRaises(readers.Unavailable) as error:
            readers.parse_kimi({"data": {}}, AT)
        self.assertEqual(error.exception.code, "vendor_usage_unavailable")

    def test_kimi_enforced_counters_outrank_legacy_ratios(self):
        windows = readers.parse_kimi({"usage": {"limit": "100", "used": "25", "remaining": "75",
            "resetTime": "2026-11-07T14:02:38Z"}, "limits": [{"window": {"duration": 300,
            "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": "20.0", "used": "10.0"}}],
            "usages": {"limit7d": {"used_ratio": 0}}}, AT)
        self.assertEqual([w["used"] for w in windows], [25, 50])
        self.assertEqual([w["key"] for w in windows], ["seven_day", "five_hour"])
        for invalid in ("NaN", "Infinity", "-1", "1e999", "private-token", True):
            value = readers.parse_kimi({"usage": {"limit": "100", "used": invalid},
                                      "usages": {"limit7d": {"used_ratio": .5}}}, AT)
            self.assertEqual(value[0]["unavailable_reason"], "unparsed")
            self.assertNotIn("used", value[0])

    def test_kimi_weekly_limit_overrides_summary_without_duplicate_windows(self):
        windows = readers.parse_kimi({"usage": {"limit": 100, "used": 25},
            "limits": [{"window": {"duration": 10080, "timeUnit": "TIME_UNIT_MINUTE"},
                        "detail": {"limit": 100, "used": 40}}]}, AT)
        self.assertEqual([(value["key"], value["used"]) for value in windows], [("seven_day", 40)])

    def test_every_provider_crosses_same_bounded_projection(self):
        for provider in ("claude", "openai", "antigravity", "grok", "kimi", "muse"):
            raw = {"provider": provider, "observed_at_ms": AT, "windows": [readers.window(
                "five_hour", "pool", 12, AT, duration=300)], "credential": "LOCAL_SECRET"}
            projected = helper.project_usage(raw, {"LOCAL_SECRET"})
            self.assertNotIn("LOCAL_SECRET", json.dumps(projected))
            self.assertEqual(projected["windows"][0]["window_duration_mins"], 300)
            raw["windows"].append(dict(raw["windows"][0]))
            with self.assertRaises(helper.SafeError):
                helper.project_usage(raw, set())

    def test_last_known_wire_retains_exact_time_and_requires_numeric_value(self):
        reading = {"id": "r", "provider": "grok", "provider_label": "Grok", "source_label": "Source",
                   "usage_source": "headless", "windows": [dict(readers.window("seven_day", "default", 28, AT),
                   last_known_reason="local_login_unavailable")]}
        snapshot = {"version": 3, "publisher": "source", "as_of_ms": AT + 5000, "readings": [reading]}
        value = validate_snapshot(snapshot)["readings"][0]["windows"][0]
        self.assertEqual(value["observed_at_ms"], AT)
        self.assertEqual(value["last_known_reason"], "local_login_unavailable")


class ProtocolTests(unittest.TestCase):
    def test_raw_provider_failure_never_crosses_helper_boundary(self):
        with patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
             patch.object(helper, "current_home", return_value=Path("/source")), \
             patch.object(helper, "profile_environment", return_value={}), \
             patch.object(readers, "collect", side_effect=ValueError("https://private/?token=SECRET")):
            result = readers.handle({"request": {"version": 1, "provider": "grok", "kind": "grok"}, "selectors": {}})
        self.assertEqual(result["error"], "source_usage_unavailable")
        self.assertNotIn("SECRET", json.dumps(result))

    def test_typed_failures_preserve_cause_without_exception_text(self):
        for error, code in ((TimeoutError("SECRET"), "source_timeout"),
                            (json.JSONDecodeError("SECRET", "SECRET", 0), "unparsed"),
                            (readers.Unavailable("local_login_unavailable"), "local_login_unavailable")):
            with self.subTest(code=code), \
                 patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
                 patch.object(helper, "current_home", return_value=Path("/source")), \
                 patch.object(helper, "profile_environment", return_value={}), \
                 patch.object(readers, "collect", side_effect=error):
                result = readers.handle({"request": {"version": 1, "provider": "grok", "kind": "grok"}, "selectors": {}})
            self.assertEqual(result["error"], code)
            self.assertNotIn("SECRET", json.dumps(result))

    def test_claude_missing_login_precedes_signed_out_metadata_failure(self):
        for contents in (None, '{"claudeAiOauth": {}}',
                         '{"claudeAiOauth": {"accessToken": ""}}'):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                # Exercise the selected profile rather than the default home.
                root = home / "selected"
                root.mkdir()
                if contents is not None:
                    (root / ".credentials.json").write_text(contents)
                env = {"HOME": directory, "CLAUDE_CONFIG_DIR": str(root)}
                with patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
                     patch.object(helper, "current_home", return_value=home), \
                     patch.object(helper, "profile_environment", return_value=env), \
                     patch.object(helper.SourceIO, "run_json", side_effect=helper.SafeError(
                         "Source provider command is unavailable")) as command, \
                     patch.object(readers, "http_json") as request:
                    result = readers.handle({"request": {"version": 1, "provider": "claude", "kind": "claude"},
                                            "selectors": {}})
                self.assertEqual(result["error"], "local_login_unavailable")
                self.assertNotIn("usage", result)
                command.assert_not_called()
                request.assert_not_called()

    def test_claude_malformed_credentials_are_not_missing_login(self):
        for contents, code in (("{SECRET", "source_usage_unavailable"),
                               ("[]", "unparsed"),
                               ('{"claudeAiOauth": []}', "unparsed")):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                (home / ".claude").mkdir()
                (home / ".claude" / ".credentials.json").write_text(contents)
                with patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
                     patch.object(helper, "current_home", return_value=home), \
                     patch.object(helper, "profile_environment", return_value={"HOME": directory}), \
                     patch.object(helper.SourceIO, "run_json") as command, \
                     patch.object(readers, "http_json") as request:
                    result = readers.handle({"request": {"version": 1, "provider": "claude", "kind": "claude"},
                                            "selectors": {}})
                self.assertEqual(result["error"], code)
                self.assertNotIn("SECRET", json.dumps(result))
                command.assert_not_called()
                request.assert_not_called()

    def test_claude_permission_command_and_network_failures_are_not_missing_login(self):
        credentials = {"claudeAiOauth": {"accessToken": "SECRET"}}
        for stage in ("credentials", "metadata", "network"):
            with self.subTest(stage=stage), \
                 patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
                 patch.object(helper, "current_home", return_value=Path("/source")), \
                 patch.object(helper, "profile_environment", return_value={}), \
                 patch.object(helper.SourceIO, "read_json", return_value=credentials,
                              side_effect=PermissionError("SECRET") if stage == "credentials" else None), \
                 patch("metadata_providers.collect", return_value={},
                       side_effect=helper.SafeError("SECRET") if stage == "metadata" else None), \
                 patch.object(readers, "http_json", side_effect=OSError("SECRET")):
                result = readers.handle({"request": {"version": 1, "provider": "claude", "kind": "claude"},
                                        "selectors": {}})
            self.assertEqual(result["error"], "source_usage_unavailable")
            self.assertNotIn("SECRET", json.dumps(result))


    def test_rpc_initialization_notification_id_matching_and_reaping(self):
        script = """
import json, sys
step = 0
for line in sys.stdin:
    value = json.loads(line)
    if step == 0:
        assert value['method'] == 'initialize'
        assert value['id'] == 1
    elif step == 1:
        assert value['method'] == 'initialized' and 'id' not in value
        step += 1
        continue
    elif step == 2:
        assert value['method'] == 'account/read'
        assert value['params'] == {'refreshToken': False}
    elif step == 3:
        assert value['method'] == 'account/rateLimits/read'
    else:
        raise AssertionError('unexpected method')
    print(json.dumps({'jsonrpc': '2.0', 'method': 'notice', 'params': {}}), flush=True)
    print(json.dumps({'jsonrpc': '2.0', 'id': value['id'], 'result': {'step': step}}), flush=True)
    step += 1
"""
        with tempfile.TemporaryDirectory() as home:
            processes = []
            popen = readers.subprocess.Popen
            def start(*args, **kwargs):
                process = popen(*args, **kwargs)
                processes.append(process)
                return process
            with patch.object(readers.subprocess, "Popen", side_effect=start):
                replies = readers.rpc([sys.executable, "-c", script], {"HOME": home, "PATH": os.defpath}, {},
                    [("account/read", {"refreshToken": False}), ("account/rateLimits/read", {})], initialized=True)
            self.assertEqual(replies, [{"step": 2}, {"step": 3}])
            self.assertIsNotNone(processes[0].poll())

    def test_rpc_timeout_reaps_owned_process(self):
        with tempfile.TemporaryDirectory() as home:
            processes = []
            popen = readers.subprocess.Popen
            def start(*args, **kwargs):
                process = popen(*args, **kwargs)
                processes.append(process)
                return process
            with patch.object(readers.subprocess, "Popen", side_effect=start), self.assertRaises(readers.Unavailable) as caught:
                readers.rpc([sys.executable, "-c", "import time; time.sleep(30)"],
                           {"HOME": home, "PATH": os.defpath}, {}, [], timeout=.05)
            self.assertEqual(caught.exception.code, "source_timeout")
            self.assertIsNotNone(processes[0].poll())

    def test_codex_signed_out_api_key_and_vendor_errors_are_distinct(self):
        quota = {"rateLimits": {"primary": {"usedPercent": 25}}}
        for answers, code in ((({"account": None, "requiresOpenaiAuth": True}, None), "local_login_unavailable"),
                              (({"account": {"type": "apiKey"}}, None), "api_key_login"),
                              ((None, None), "vendor_usage_unavailable"),
                              (({"account": {"type": "chatgpt", "email": "a@example.test"}}, None), "vendor_usage_unavailable")):
            with self.subTest(code=code, answers=answers), patch.object(readers, "rpc", return_value=answers):
                with self.assertRaises(readers.Unavailable) as caught:
                    readers.collect("openai", Path("/source"), {}, None)
                self.assertEqual(caught.exception.code, code)
        with patch.object(readers, "rpc", return_value=({"account": {"type": "chatgpt", "email": "a@example.test"}}, quota)):
            _, usage = readers.collect("openai", Path("/source"), {}, None)
        self.assertEqual(usage["windows"][0]["used"], 25)

    def test_grok_signed_out_and_vendor_errors_are_distinct(self):
        billing = {"config": {"creditUsagePercent": 28}}
        for answers, code in ((({"authenticated": False}, None), "local_login_unavailable"),
                              ((None, None), "vendor_usage_unavailable"),
                              (({"authenticated": True, "meta": {"email": "a@example.test"}}, None), "vendor_usage_unavailable")):
            with self.subTest(code=code), patch.object(readers, "rpc", return_value=answers):
                with self.assertRaises(readers.Unavailable) as caught:
                    readers.collect("grok", Path("/source"), {}, None)
                self.assertEqual(caught.exception.code, code)
        with patch.object(readers, "rpc", return_value=({"authenticated": True, "meta": {"email": "a@example.test",
                "team_id": "team-1", "subscription_tier": "SuperGrok"}}, billing)):
            account, usage = readers.collect("grok", Path("/source"), {}, None)
        self.assertEqual((account["principal"], account["organization_id"]), ("a@example.test", "team-1"))
        self.assertEqual(usage["windows"][0]["used"], 28)

    def test_shared_workspace_or_team_id_is_never_the_principal(self):
        quota = {"accountId": "shared-workspace", "rateLimits": {"primary": {"usedPercent": 25}}}
        with patch.object(readers, "rpc", return_value=({"account": {"type": "chatgpt", "email": None, "planType": "team"}}, quota)):
            account, usage = readers.collect("openai", Path("/source"), {}, None)
        self.assertIsNone(account)
        self.assertEqual(usage["windows"][0]["used"], 25)
        with patch.object(readers, "rpc", return_value=({"account": {"type": "chatgpt", "email": "a@example.test"}}, quota)):
            account, _ = readers.collect("openai", Path("/source"), {}, None)
        self.assertEqual((account["principal"], account["workspace_id"]), ("a@example.test", "shared-workspace"))
        with patch.object(readers, "rpc", return_value=({"authenticated": True, "meta": {"team_id": "shared-team"}},
                                                       {"config": {"creditUsagePercent": 5}})):
            account, usage = readers.collect("grok", Path("/source"), {}, None)
        self.assertIsNone(account)
        self.assertEqual(usage["windows"][0]["used"], 5)
        with patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
             patch.object(helper, "current_home", return_value=Path("/source")), \
             patch.object(helper, "profile_environment", return_value={}), \
             patch.object(readers, "rpc", return_value=({"account": {"type": "chatgpt"}}, quota)):
            result = readers.handle({"request": {"version": 1, "provider": "openai", "kind": "codex"}, "selectors": {}})
        self.assertNotIn("metadata", result)
        self.assertNotIn("shared-workspace", json.dumps(result))
        self.assertEqual(result["usage"]["windows"][0]["used"], 25)

    def test_expired_claude_login_is_reported_without_refresh_or_request(self):
        for expires, expired in ((int(time.time() * 1000) - 1, True), (0, True),
                                 (int(time.time() * 1000) + 3600000, False), (None, False)):
            with self.subTest(expires=expires), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                (home / ".claude").mkdir()
                oauth = {"accessToken": "SECRET", "refreshToken": "REFRESH"}
                if expires is not None:
                    oauth["expiresAt"] = expires
                (home / ".claude" / ".credentials.json").write_text(json.dumps({"claudeAiOauth": oauth}))
                with patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
                     patch.object(helper, "current_home", return_value=home), \
                     patch.object(helper, "profile_environment", return_value={"HOME": directory}), \
                     patch("metadata_providers.collect", return_value={"principal": "a@example.test",
                           "principal_kind": "email", "label": "a@example.test"}) as status, \
                     patch.object(readers, "http_json", return_value={"five_hour": {"utilization": 3}}) as request:
                    result = readers.handle({"request": {"version": 1, "provider": "claude", "kind": "claude"},
                                             "selectors": {}})
                if expired:
                    self.assertEqual(result["error"], "web_login_expired")
                    status.assert_not_called()
                    request.assert_not_called()
                else:
                    self.assertNotIn("error", result)
                    self.assertEqual(request.call_args.args[1]["Authorization"], "Bearer SECRET")
                self.assertNotIn("SECRET", json.dumps(result))

    def test_rpc_call_error_is_classified_by_caller_but_initialize_error_is_vendor(self):
        script = """
import json, sys
for line in sys.stdin:
    value = json.loads(line)
    if 'id' not in value:
        continue
    if value['method'] == '{failing}':
        print(json.dumps({'jsonrpc': '2.0', 'id': value['id'], 'error': {'code': -32600, 'message': 'SECRET'}}), flush=True)
    else:
        print(json.dumps({'jsonrpc': '2.0', 'id': value['id'], 'result': {'method': value['method']}}), flush=True)
"""
        with tempfile.TemporaryDirectory() as home:
            env = {"HOME": home, "PATH": os.defpath}
            replies = readers.rpc([sys.executable, "-c", script.replace("{failing}", "quota")], env, {},
                                  [("account", {}), ("quota", {})], initialized=True)
            self.assertEqual(replies, [{"method": "account"}, None])
            with self.assertRaises(readers.Unavailable) as caught:
                readers.rpc([sys.executable, "-c", script.replace("{failing}", "initialize")], env, {}, [("account", {})])
            self.assertEqual(caught.exception.code, "vendor_usage_unavailable")

    def test_claude_authoritative_limits_win_without_dropping_scopes(self):
        windows = readers.parse_claude({"limits": [
            {"kind": "session", "percent": None, "remaining_percentage": 91,
             "resets_at": "2026-11-04T00:00:00.123Z"},
            {"kind": "weekly_all", "percent": 7},
            {"kind": "weekly_all", "percent": 33, "scope": {"model": "opus"}}],
            "five_hour": {"utilization": 80}, "seven_day": {"utilization": 90},
            "spend": {"percent": 99, "resets_at": "2026-11-04T00:00:00Z"}}, AT)
        self.assertEqual(len(windows), 3)
        self.assertEqual([w["used"] for w in windows], [9, 7, 33])
        self.assertEqual(windows[2]["pool"], '{"model":"opus"}')
        self.assertEqual(windows[0]["resets_at_ms"] % 1000, 123)


    def test_cold_muse_reports_awaiting_turn_without_fabricating_identity(self):
        quota = {"provider": "muse", "windows": [], "observed_at_ms": AT,
                 "unavailable_reason": "server_sent_no_usage"}
        with patch("metadata_providers.collect_usage", return_value=quota) as usage, \
             patch("metadata_providers.collect", side_effect=ValueError("identity not yet cached")):
            metadata, value = readers.collect("muse", Path("/source"), {"USAGE_SOURCE_KIND": "muse"}, None)
        self.assertIsNone(metadata)
        self.assertEqual(value, quota)


if __name__ == "__main__":
    unittest.main()
