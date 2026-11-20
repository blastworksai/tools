"""Provider protocol projection without live logins or model turns."""
import hashlib
import json
import logging
from pathlib import Path
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import provider_metadata as helper
from usage_service import readers
from usage_service.process_supervisor import BoundedError, Result, TIMEOUT, UNAVAILABLE
from usage_service.protocol import ServiceError, validate_snapshot

AT = 1800000000123


class RpcSession:
    def __init__(self, account, quota, events):
        self.account = account
        self.quota = quota
        self.events = events
        self.pending = None
        self.stdin_closed = False
        self.close_result = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def write(self, data):
        message = json.loads(data)
        method = message["method"]
        refresh = message.get("params", {}).get("refreshToken")
        self.events.append(("write", method, refresh))
        if "id" not in message:
            return
        if method == "initialize":
            response = {"jsonrpc": "2.0", "id": message["id"], "result": {}}
        elif method == "account/read":
            response = {"jsonrpc": "2.0", "id": message["id"], "result": self.account}
        elif self.quota is None:
            response = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -1}}
        else:
            response = {"jsonrpc": "2.0", "id": message["id"], "result": self.quota}
        self.pending = (method, refresh, response)

    def readline(self, limit=65536):
        if self.pending is None:
            raise AssertionError("read without a response-producing write")
        method, refresh, response = self.pending
        self.pending = None
        self.events.append(("read", method, refresh))
        return json.dumps(response).encode() + b"\n"

    def close_stdin(self):
        self.stdin_closed = True

    def close(self):
        if self.close_result is None:
            self.close_result = Result(0)
        return self.close_result


class StdoutSession:
    def __init__(self, lines=(), error=None):
        self.lines = list(lines)
        self.error = error
        self.close_result = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def readline(self, limit=65536):
        if self.error is not None:
            raise self.error
        return self.lines.pop(0) if self.lines else b""

    def write(self, data):
        raise AssertionError("Kimi stdin must stay unused")

    def close_stdin(self):
        pass

    def close(self):
        if self.close_result is None:
            self.close_result = Result(None)
        return self.close_result


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

    def test_the_named_provider_file_is_the_one_launched(self):
        login = {"account": {"type": "chatgpt", "email": "fixture@example.test"}}
        launched = []
        def fake_rpc(argv, *_args, **_kwargs):
            launched.append(argv[0])
            return login, {"rateLimits": {}}
        for command, expected in ((None, "codex"), ("/opt/custom/codex/bin/codex", "/opt/custom/codex/bin/codex")):
            launched.clear()
            with patch.object(readers, "rpc", side_effect=fake_rpc):
                readers.collect("openai", Path("/source"), {}, None, command)
            self.assertEqual(launched[0], expected)
        seen = []
        def fake_stdout(argv, *_args, **_kwargs):
            seen.append(argv[0])
            return b""
        with patch.object(readers, "_bounded_stdout", side_effect=fake_stdout), \
             patch("metadata_providers.collect", return_value={}):
            readers.collect("antigravity", Path("/source"), {}, None, "/opt/agy/bin/agy")
        self.assertEqual(seen, ["/opt/agy/bin/agy"])

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
    def setUp(self):
        platform = patch.object(readers.sys, "platform", "linux")
        platform.start()
        self.addCleanup(platform.stop)

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
                command.assert_called()
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


    def test_claude_token_renewed_by_auth_status_is_the_one_sent(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".claude").mkdir()
            path = home / ".claude" / ".credentials.json"
            path.write_text(json.dumps({"claudeAiOauth": {"accessToken": "STALE", "expiresAt": 1}}))

            def renew(*args, **kwargs):
                # The CLI refreshes its own login while reporting status.
                path.write_text(json.dumps({"claudeAiOauth": {"accessToken": "FRESH",
                                "expiresAt": int(time.time() * 1000) + 3600000}}))
                return {"principal": "a@example.test", "principal_kind": "email", "label": "a@example.test"}
            with patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
                 patch.object(helper, "current_home", return_value=home), \
                 patch.object(helper, "profile_environment", return_value={"HOME": directory}), \
                 patch("metadata_providers.collect", side_effect=renew), \
                 patch.object(readers, "http_json", return_value={"five_hour": {"utilization": 3}}) as request:
                result = readers.handle({"request": {"version": 1, "provider": "claude", "kind": "claude"},
                                         "selectors": {}})
        self.assertNotIn("error", result)
        self.assertEqual(request.call_args.args[1]["Authorization"], "Bearer FRESH")

    def test_claude_rejected_and_forbidden_tokens_are_distinct_but_kimi_is_unchanged(self):
        import urllib.error

        def refuse(code):
            def open_(request, timeout=None):
                raise urllib.error.HTTPError(request.full_url, code, "SECRET", {}, None)
            return open_
        credentials = {"claudeAiOauth": {"accessToken": "SECRET", "expiresAt": int(time.time() * 1000) + 3600000}}
        for code, claude in ((401, "web_login_expired"), (403, "web_login_forbidden")):
            with self.subTest(code=code), \
                 patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
                 patch.object(helper, "current_home", return_value=Path("/source")), \
                 patch.object(helper, "profile_environment", return_value={}), \
                 patch.object(helper.SourceIO, "read_json", return_value=credentials), \
                 patch("metadata_providers.collect", return_value={"principal": "a@example.test",
                       "principal_kind": "email", "label": "a@example.test"}), \
                 patch("urllib.request.OpenerDirector.open", side_effect=refuse(code)):
                result = readers.handle({"request": {"version": 1, "provider": "claude", "kind": "claude"},
                                         "selectors": {}})
                self.assertEqual(result["error"], claude)
                self.assertNotIn("SECRET", json.dumps(result))
                with self.assertRaises(readers.Unavailable) as kimi:
                    readers.http_json("http://127.0.0.1:1/api/v1/oauth/usage", {})
                self.assertEqual(kimi.exception.args[0], "local_login_unavailable")

    def test_rpc_initialization_notification_id_matching_and_interactive_session(self):
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
            bounded = readers.interactive_bounded
            with patch.object(readers, "interactive_bounded", side_effect=bounded) as run:
                replies = readers.rpc([sys.executable, "-c", script], {"HOME": home, "PATH": os.defpath}, {},
                    [("account/read", {"refreshToken": False}), ("account/rateLimits/read", {})], initialized=True)
            self.assertEqual(replies, [{"step": 2}, {"step": 3}])
            self.assertEqual(run.call_args.args[2], home)

    def test_rpc_writes_follow_their_corresponding_responses(self):
        events = []
        session = RpcSession({"step": 2}, {"step": 3}, events)
        with patch.object(readers, "interactive_bounded", return_value=session):
            replies = readers.rpc(["codex"], {"HOME": "/source"}, {},
                [("account/read", {"refreshToken": False}), ("account/rateLimits/read", {})], initialized=True)
        self.assertEqual(replies, [{"step": 2}, {"step": 3}])
        self.assertEqual(events, [
            ("write", "initialize", None), ("read", "initialize", None),
            ("write", "initialized", None),
            ("write", "account/read", False), ("read", "account/read", False),
            ("write", "account/rateLimits/read", None), ("read", "account/rateLimits/read", None),
        ])
        self.assertTrue(session.stdin_closed)
        self.assertIsNotNone(session.close_result)

    def test_codex_renewal_response_precedes_quota_write(self):
        quota = {"rateLimits": {"primary": {"usedPercent": 25}}}
        signed_out = {"account": None, "requiresOpenaiAuth": True}
        signed_in = {"account": {"type": "chatgpt", "email": "a@example.test"}}
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".codex").mkdir()
            (home / ".codex" / "auth.json").write_text("{}")
            first_events, second_events = [], []
            sessions = [RpcSession(signed_out, None, first_events),
                        RpcSession(signed_in, quota, second_events)]
            with patch.object(readers, "interactive_bounded", side_effect=sessions) as run:
                _, usage = readers.collect("openai", home, {"HOME": directory}, None)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(usage["windows"][0]["used"], 25)
        self.assertEqual(second_events, [
            ("write", "initialize", None), ("read", "initialize", None),
            ("write", "initialized", None),
            ("write", "account/read", True), ("read", "account/read", True),
            ("write", "account/rateLimits/read", None), ("read", "account/rateLimits/read", None),
        ])
        self.assertEqual(sum(event[0] == "write" and event[1] == "account/read" and event[2] is True
                             for event in first_events + second_events), 1)

    def test_rpc_timeout_uses_bounded_process_category(self):
        with tempfile.TemporaryDirectory() as home:
            bounded = readers.interactive_bounded
            with patch.object(readers, "interactive_bounded", side_effect=bounded) as run, \
                 self.assertRaises(readers.Unavailable) as caught:
                readers.rpc([sys.executable, "-c", "import time; time.sleep(30)"],
                           {"HOME": home, "PATH": os.defpath}, {}, [], timeout=.05)
            self.assertEqual(caught.exception.code, "source_timeout")
            run.assert_called_once()

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

    def test_codex_expired_login_is_renewed_once_by_codex_or_reported_expired(self):
        quota = {"rateLimits": {"primary": {"usedPercent": 25}}}
        signed_out = ({"account": None, "requiresOpenaiAuth": True}, None)
        signed_in = ({"account": {"type": "chatgpt", "email": "a@example.test"}}, quota)
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".codex").mkdir()
            (home / ".codex" / "auth.json").write_text("{}")
            calls = []
            def renewed(argv, env, initialize, calls_made, **kwargs):
                calls.append(calls_made[0][1]["refreshToken"])
                return signed_in if calls_made[0][1]["refreshToken"] else signed_out
            with patch.object(readers, "rpc", side_effect=renewed):
                _, usage = readers.collect("openai", home, {}, None)
            self.assertEqual(calls, [False, True])
            self.assertEqual(usage["windows"][0]["used"], 25)
            with patch.object(readers, "rpc", return_value=signed_out) as rpc, self.assertRaises(readers.Unavailable) as caught:
                readers.collect("openai", home, {}, None)
            self.assertEqual(caught.exception.code, "web_login_expired")
            self.assertEqual(rpc.call_count, 2)
            # CODEX_HOME decides where the saved login lives.
            with patch.object(readers, "rpc", return_value=signed_out) as rpc, self.assertRaises(readers.Unavailable) as caught:
                readers.collect("openai", home, {"CODEX_HOME": str(home / "other")}, None)
            self.assertEqual(caught.exception.code, "local_login_unavailable")
            self.assertEqual(rpc.call_count, 1)
            with patch.object(readers, "rpc", return_value=signed_in) as rpc:
                readers.collect("openai", home, {}, None)
            self.assertEqual(rpc.call_count, 1)

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
        # SKILLS-217: a stale access token is "login expired" only when the login (its
        # refresh token) has ended too; with a live login it is access_token_stale.
        now = int(time.time() * 1000)
        live, ended = now + 86400000, now - 1
        live_s, ended_s = (now + 86400000) // 1000, now // 1000 - 60
        for expires, refresh, refresh_expires, expected in (
                (now - 1, "REFRESH", live, "access_token_stale"), (0, "REFRESH", None, "access_token_stale"),
                (now - 1, "REFRESH", ended, "web_login_expired"), (now - 1, None, None, "web_login_expired"),
                (now - 1, "", live, "web_login_expired"),
                (now + 3600000, "REFRESH", live, None), (None, "REFRESH", None, None),
                # Kimi round 1: blank refresh tokens and malformed refresh expiries fail closed.
                (now - 1, "   ", live, "web_login_expired"), (now - 1, "REFRESH", "0", "web_login_expired"),
                (now - 1, "REFRESH", True, "web_login_expired"), (now - 1, "REFRESH", {"at": live}, "web_login_expired"),
                (now - 1, "REFRESH", float("nan"), "web_login_expired"), (now - 1, "REFRESH", float("inf"), "web_login_expired"),
                # Seconds and milliseconds both read right, for either stamp.
                (now - 1, "REFRESH", live_s, "access_token_stale"), (now - 1, "REFRESH", ended_s, "web_login_expired"),
                (now // 1000 - 60, "REFRESH", live, "access_token_stale"), ((now + 3600000) // 1000, "REFRESH", live, None)):
            expired = expected is not None
            with self.subTest(expires=expires, refresh=refresh, refresh_expires=refresh_expires), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                (home / ".claude").mkdir()
                oauth = {"accessToken": "SECRET"}
                if refresh is not None:
                    oauth["refreshToken"] = refresh
                if refresh_expires is not None:
                    oauth["refreshTokenExpiresAt"] = refresh_expires
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
                    self.assertEqual(result["error"], expected)
                    status.assert_called_once()
                    request.assert_not_called()
                else:
                    self.assertNotIn("error", result)
                    self.assertEqual(request.call_args.args[1]["Authorization"], "Bearer SECRET")
                self.assertNotIn("SECRET", json.dumps(result))
                self.assertNotIn("REFRESH", json.dumps(result))

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


class KeychainTests(unittest.TestCase):
    def setUp(self):
        platform = patch.object(readers.sys, "platform", "darwin")
        account = patch.object(readers, "_keychain_account", return_value="fixture-user")
        platform.start()
        account.start()
        self.addCleanup(platform.stop)
        self.addCleanup(account.stop)
        self.metadata = {"principal": "a@example.test", "principal_kind": "email", "label": "a@example.test"}

    def handle(self, home, env, security, *, metadata=None):
        command_options = {"side_effect": security} if callable(security) else {"return_value": security}
        with patch.object(helper, "source_identity", return_value={"source_uid": "1000"}), \
             patch.object(helper, "current_home", return_value=home), \
             patch.object(helper, "profile_environment", return_value=env), \
             patch.object(readers, "run_bounded", **command_options) as command, \
             patch("metadata_providers.collect", side_effect=metadata) if metadata is not None else \
                 patch("metadata_providers.collect", return_value=self.metadata), \
             patch.object(readers, "http_json", return_value={"five_hour": {"utilization": 3}}) as request:
            result = readers.handle({"request": {"version": 1, "provider": "claude", "kind": "claude"},
                                    "selectors": {}})
        return result, command, request

    def test_keychain_token_renewed_by_auth_status_is_the_one_sent(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            document = {"claudeAiOauth": {"accessToken": "STALE", "expiresAt": 1}}

            def renew(*args):
                nonlocal document
                document = {"claudeAiOauth": {"accessToken": "FRESH",
                                "refreshToken": "REFRESH", "expiresAt": int(time.time() * 1000) + 3600000}}
                return self.metadata

            def security(*args):
                return Result(0, json.dumps(document).encode())

            result, command, request = self.handle(home, {"HOME": directory}, security, metadata=renew)
        self.assertNotIn("error", result)
        self.assertEqual(request.call_args.args[1]["Authorization"], "Bearer FRESH")
        argv = command.call_args.args[0]
        self.assertEqual(argv, ["/usr/bin/security", "find-generic-password", "-a", "fixture-user",
                                "-s", "Claude Code-credentials", "-w"])
        self.assertNotIn("FRESH", repr(argv))
        self.assertNotIn("REFRESH", json.dumps(result))

    def test_expired_keychain_token_is_not_sent(self):
        with tempfile.TemporaryDirectory() as directory:
            security = Result(0, json.dumps({"claudeAiOauth": {
                "accessToken": "EXPIRED", "expiresAt": 1}}).encode())
            result, _, request = self.handle(Path(directory), {"HOME": directory}, security)
        self.assertEqual(result["error"], "web_login_expired")
        request.assert_not_called()
        self.assertNotIn("EXPIRED", json.dumps(result))

    def test_custom_config_directory_selects_scoped_item_then_file_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / "selected"
            root.mkdir()
            (root / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
                "accessToken": "FILE_TOKEN", "expiresAt": int(time.time() * 1000) + 3600000}}))
            security = Result(44, b"", b"missing fixture", UNAVAILABLE)
            result, command, request = self.handle(home, {"HOME": directory, "CLAUDE_CONFIG_DIR": str(root)}, security)
        expected = "Claude Code-credentials-" + hashlib.sha256(str(root).encode()).hexdigest()[:8]
        self.assertNotIn("error", result)
        self.assertEqual(command.call_args.args[0][5], expected)
        self.assertEqual(request.call_args.args[1]["Authorization"], "Bearer FILE_TOKEN")
        self.assertNotIn("FILE_TOKEN", repr(command.call_args.args[0]))
        self.assertNotIn("FILE_TOKEN", json.dumps(result))

    def test_locked_unavailable_and_timed_out_keychain_never_falls_back_or_unlocks(self):
        cases = ((Result(45, b"", b"locked fixture", UNAVAILABLE), "local_login_unavailable"),
                 (Result(None, b"", b"denied fixture", UNAVAILABLE), "local_login_unavailable"),
                 (Result(None, error=TIMEOUT), "source_timeout"))
        for security, code in cases:
            with self.subTest(code=code, status=security.status), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                (home / ".claude").mkdir()
                (home / ".claude" / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
                    "accessToken": "MUST_NOT_BE_READ", "expiresAt": int(time.time() * 1000) + 3600000}}))
                with patch.object(helper.SourceIO, "read_json", side_effect=AssertionError("fallback called")) as fallback:
                    result, command, request = self.handle(home, {"HOME": directory}, security)
                self.assertEqual(result["error"], code)
                fallback.assert_not_called()
                request.assert_not_called()
                argv = command.call_args.args[0]
                self.assertNotIn("unlock-keychain", argv)
                self.assertNotIn("MUST_NOT_BE_READ", repr(argv))
                self.assertNotIn("MUST_NOT_BE_READ", json.dumps(result))

    def test_missing_keychain_item_and_file_is_missing_login(self):
        with tempfile.TemporaryDirectory() as directory:
            security = Result(44, b"", b"missing fixture", UNAVAILABLE)
            result, _, request = self.handle(Path(directory), {"HOME": directory}, security)
        self.assertEqual(result["error"], "local_login_unavailable")
        request.assert_not_called()

    def test_malformed_keychain_json_preserves_existing_failure_codes(self):
        for raw, code in ((b"{SECRET", "source_usage_unavailable"), (b"[]", "unparsed")):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                result, command, request = self.handle(Path(directory), {"HOME": directory}, Result(0, raw))
                self.assertEqual(result["error"], code)
                request.assert_not_called()
                self.assertNotIn("SECRET", json.dumps(result))
                self.assertNotIn("SECRET", repr(command.call_args.args[0]))

    def test_tokens_are_absent_from_logs_rpc_snapshot_and_diagnostic_argv(self):
        records = []

        class Capture(logging.Handler):
            def emit(self, record):
                records.append(record.getMessage())

        handler = Capture(level=logging.DEBUG)
        logger = logging.getLogger()
        logger.addHandler(handler)
        old_level = logger.level
        logger.setLevel(logging.DEBUG)
        try:
            with tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                security = Result(0, json.dumps({"claudeAiOauth": {
                    "accessToken": "ACCESS_SECRET", "refreshToken": "REFRESH_SECRET",
                    "expiresAt": int(time.time() * 1000) + 3600000}}).encode(), b"diagnostic ACCESS_SECRET")
                result, command, _ = self.handle(home, {"HOME": directory}, security)
            snapshot = validate_snapshot({"version": 3, "publisher": "source", "as_of_ms": AT,
                "readings": [{"id": "r", "provider": "claude", "provider_label": "Claude",
                              "source_label": "Source", "usage_source": "headless",
                              "windows": result["usage"]["windows"]}]})
            outputs = {"rpc": json.dumps(result), "snapshot": json.dumps(snapshot),
                       "argv": repr(command.call_args.args[0]), "logs": "\n".join(records)}
            for name, output in outputs.items():
                with self.subTest(output=name):
                    self.assertNotIn("ACCESS_SECRET", output)
                    self.assertNotIn("REFRESH_SECRET", output)
        finally:
            logger.removeHandler(handler)
            logger.setLevel(old_level)


class BoundedReaderTests(unittest.TestCase):
    def test_antigravity_projects_remaining_quota_as_used(self):
        raw = b"Gemini Models\tWeekly Limit Remaining\t100%\t\n"
        env = {"HOME": "/source", "USAGE_SOURCE_KIND": "agy"}
        with patch.object(readers, "run_bounded", return_value=Result(0, raw)), \
             patch("metadata_providers.collect", return_value={}):
            _, usage = readers.collect("antigravity", Path("/source"), env, None)
        self.assertEqual(usage["windows"][0]["used"], 0)

    def test_kimi_uses_only_own_child_url_and_token(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / ".kimi-code"
            root.mkdir()
            (root / "server.token").write_text("STALE_SECRET")
            env = {"HOME": directory}
            io = helper.SourceIO(home, env)
            sessions = []
            requests = []

            def interactive(argv, *args):
                base = "http://127.0.0.1:" + argv[-1]
                session = StdoutSession([b"starting\n", (base + "/#token=OWN_CHILD_SECRET\n").encode()])
                sessions.append(session)
                return session

            def request(url, headers, **kwargs):
                requests.append((url, headers))
                if url.endswith("/shutdown"):
                    return {}
                if url.endswith("/userinfo"):
                    return {"data": {"userId": "fixture"}}
                return {"data": {"quota": {"usages": {"limit5h": {"usedRatio": 0}}}}}

            with patch.object(readers, "interactive_bounded", side_effect=interactive) as run, \
                 patch.object(helper.SourceIO, "_read", side_effect=AssertionError("stale token file read")) as stale, \
                 patch.object(readers, "http_json", side_effect=request):
                account, quota = readers.kimi(env, io)
        base = "http://127.0.0.1:" + run.call_args.args[0][-1]
        self.assertEqual(account["data"]["userId"], "fixture")
        self.assertEqual(quota["data"]["quota"]["usages"]["limit5h"]["usedRatio"], 0)
        stale.assert_not_called()
        self.assertEqual([url for url, _ in requests], [
            base + "/api/v1/oauth/userinfo", base + "/api/v1/oauth/usage", base + "/api/v1/shutdown"])
        self.assertTrue(all(headers["Authorization"] == "Bearer OWN_CHILD_SECRET" for _, headers in requests))
        self.assertNotIn("OWN_CHILD_SECRET", repr(run.call_args))
        self.assertNotIn("STALE_SECRET", repr(run.call_args))
        self.assertNotIn("OWN_CHILD_SECRET", json.dumps([account, quota]))
        self.assertIsNotNone(sessions[0].close_result)

    def test_kimi_rejects_unrelated_url_and_never_reads_stale_token(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / ".kimi-code"
            root.mkdir()
            (root / "server.token").write_text("STALE_SECRET")
            env = {"HOME": directory}
            io = helper.SourceIO(home, env)
            session = StdoutSession([b"http://127.0.0.1:1/#token=STALE_SECRET\n"])
            with patch.object(readers, "interactive_bounded", return_value=session), \
                 patch.object(helper.SourceIO, "_read", side_effect=AssertionError("stale token file read")) as stale, \
                 patch.object(readers, "http_json") as request, \
                 self.assertRaises(readers.Unavailable) as caught:
                readers.kimi(env, io)
        self.assertEqual(caught.exception.code, "source_usage_unavailable")
        stale.assert_not_called()
        request.assert_not_called()
        self.assertIsNotNone(session.close_result)

    def test_kimi_readiness_timeout_preserves_bounded_error_and_closes(self):
        session = StdoutSession(error=BoundedError(TIMEOUT))
        with patch.object(readers, "interactive_bounded", return_value=session), \
             patch.object(readers, "http_json") as request, \
             self.assertRaises(readers.Unavailable) as caught:
            readers.kimi({"HOME": "/source"}, None)
        self.assertEqual(caught.exception.code, "source_timeout")
        request.assert_not_called()
        self.assertIsNotNone(session.close_result)


if __name__ == "__main__":
    unittest.main()
