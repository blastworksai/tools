"""Fixed, usage-only provider reads. Never a prompt or an arbitrary command.

Raw vendor answers and credentials live only in the short-lived provider-read
helper. Only project_metadata/project_usage output may cross its stdout boundary.
"""
from __future__ import annotations

from datetime import datetime
import getpass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import sys
import time
import unicodedata
import urllib.request
import urllib.error

import provider_metadata as helper
from .process_supervisor import BoundedError, TIMEOUT, interactive_bounded, run_bounded


class Unavailable(helper.SafeError):
    def __init__(self, code="source_usage_unavailable"):
        self.code = code
        super().__init__(code)


def obj(value):
    if not isinstance(value, dict):
        raise Unavailable("unparsed")
    return value


def _epoch_ms(value):
    """A credential timestamp in milliseconds, or None when it is not a finite number.

    A positive value below 1e11 is taken as seconds and scaled (SKILLS-217)."""
    # A Python int is always finite; only a float can be NaN or infinite (and
    # math.isfinite on a huge int would raise OverflowError).
    if type(value) not in (int, float) or (type(value) is float and not math.isfinite(value)):
        return None
    return value * 1000 if 0 < value < 1e11 else value


def name(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 128 or not value.isprintable():
        raise Unavailable("unparsed")
    return value


def instant(value):
    if value is None:
        return None
    try:
        if isinstance(value, str):
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                return None
            value = parsed.timestamp()
        if type(value) not in (int, float) or not math.isfinite(value) or not 1_000_000_000 <= value <= 4_102_444_800:
            return None
        return round(value * 1000)
    except ValueError:
        return None


def window(key, pool, value, observed, *, remaining=False, reset=None, duration=None):
    result = {"key": name(key), "pool": name(pool), "observed_at_ms": observed}
    if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 100:
        result["unavailable_reason"] = "not_reported" if value is None else "unparsed"
    else:
        result.update(used=100 - value if remaining else value,
                      remaining=value if remaining else 100 - value)
    at = instant(reset)
    if at is not None:
        result["resets_at_ms"] = at
    if type(duration) is int and 0 < duration <= 525600:
        result["window_duration_mins"] = duration
    return result


def parse_claude(document, observed):
    document = obj(document)
    windows, claimed = [], set()
    used_fields = ("percent", "utilization", "used_percentage", "used_percent")
    remaining_fields = ("remaining_percentage", "remaining_percent")
    reset_fields = ("resets_at", "reset_at", "resets_at_utc", "resets")
    def project(key, value, pool="default"):
        key = {"session": "five_hour", "weekly_all": "seven_day"}.get(key, key)
        if key.startswith("seven_day_") and pool == "default":
            pool, key = key[len("seven_day_"):], "seven_day"
        percent, remaining = None, False
        for field in (*used_fields, *remaining_fields):
            if value.get(field) is not None:
                percent, remaining = value[field], field in remaining_fields
                break
        reset = next((value[field] for field in reset_fields if value.get(field) is not None), None)
        return window(key, pool, percent, observed, remaining=remaining, reset=reset,
                      duration={"five_hour": 300, "seven_day": 10080}.get(key))
    # Limits entries are authoritative by window identity, never by percentage.
    limits = document.get("limits", [])
    if not isinstance(limits, list):
        raise Unavailable("unparsed")
    for value in limits:
        value = obj(value)
        scope = value.get("scope")
        if scope is not None and not isinstance(scope, dict):
            raise Unavailable("unparsed")
        pool = "default" if not scope else json.dumps(scope, sort_keys=True, separators=(",", ":"))
        entry = project(name(value.get("kind")), value, pool)
        pair = (entry["key"], entry["pool"])
        if pair in claimed:
            raise Unavailable("unparsed")
        claimed.add(pair)
        windows.append(entry)
    for key, value in document.items():
        if not isinstance(value, dict) or key in {"extra_usage", "seven_day_breakdown", "spend"}:
            continue
        known = key in {"five_hour", "seven_day"} or key.startswith("seven_day_")
        shaped = any(field in value for field in reset_fields) and any(field in value for field in (*used_fields, *remaining_fields))
        if not known and not shaped:
            continue
        entry = project(key, value)
        if (entry["key"], entry["pool"]) not in claimed:
            windows.append(entry)
    return windows


def parse_codex(document, observed):
    document = obj(document)
    by_id = document.get("rateLimitsByLimitId")
    buckets = list(by_id.items()) if isinstance(by_id, dict) and by_id else [("default", document.get("rateLimits"))]
    windows = []
    for identifier, bucket in buckets:
        bucket = obj(bucket)
        pool = bucket.get("limitId") or identifier
        for slot in ("primary", "secondary"):
            if bucket.get(slot) is None:
                continue
            value = obj(bucket[slot])
            duration = value.get("windowDurationMins")
            key = {300: "five_hour", 10080: "seven_day"}.get(duration) if type(duration) is int else None
            key = key or (slot + ":" + str(duration) + "m" if type(duration) is int and duration > 0 else slot)
            windows.append(window(key, pool, value.get("usedPercent"), observed, reset=value.get("resetsAt"), duration=duration))
    return windows


def codex_credit_balance(document):
    # Credits are an account balance, not a denominator for rolling windows.
    # Only the authoritative single-bucket view supplies this display value.
    bucket = document.get("rateLimits")
    credits = bucket.get("credits") if isinstance(bucket, dict) else None
    if not isinstance(credits, dict) or credits.get("unlimited") is not False:
        return None
    if type(credits.get("hasCredits")) is not bool:
        return None
    balance = credits.get("balance")
    if (not isinstance(balance, str) or len(balance) > 128
            or re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", balance) is None):
        return None
    value = float(balance)
    return value if math.isfinite(value) and value <= 9_007_199_254_740_991 else None


def parse_agy(text, observed):
    groups = {"gemini models": "gemini", "claude and gpt models": "claude_gpt"}
    buckets = {"weekly limit remaining": "seven_day", "five hour limit remaining": "five_hour"}
    windows = []
    for line in text.splitlines():
        cells = [cell.strip() for cell in line.split("\t")]
        if len(cells) != 4:
            continue
        group, bucket, percent, reset = cells
        if group.lower() not in groups or bucket.lower() not in buckets:
            continue
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)%", percent)
        key = buckets[bucket.lower()]
        windows.append(window(key, groups[group.lower()], float(match[1]) if match else percent, observed,
                              remaining=True, reset=reset, duration=300 if key == "five_hour" else 10080))
    return windows


def parse_grok(document, observed):
    config = obj(obj(document).get("config"))
    period = obj(config.get("currentPeriod", {}))
    kind = period.get("type", "period")
    weekly = kind in {"USAGE_PERIOD_TYPE_WEEKLY", "weekly"}
    return [window("seven_day" if weekly else name(kind), "grok", config.get("creditUsagePercent"),
                   observed, reset=period.get("end"), duration=10080 if weekly else None)]


def parse_kimi(document, observed):
    document = obj(document)
    data = document.get("data", {})
    holders = [document, document.get("quota"), data, data.get("quota") if isinstance(data, dict) else None]
    holder = next((v for v in holders if isinstance(v, dict) and ("usage" in v or "limits" in v)), None)
    if holder is not None:
        # Newer Kimi surfaces expose enforced counters; these outrank the older
        # informational usages ratios regardless of whether either reports zero.
        windows = {}
        def counter(key, detail, duration=None):
            detail = obj(detail)
            def number(value):
                if isinstance(value, str):
                    if len(value) > 128 or re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value) is None:
                        return None
                    value = float(value)
                return value if type(value) in (int, float) and math.isfinite(value) and value >= 0 else None
            limit, used = number(detail.get("limit")), number(detail.get("used"))
            valid = limit is not None and used is not None and limit > 0 and used <= limit
            entry = window(key, "default", used / limit * 100 if valid else None,
                           observed, reset=detail.get("resetTime"), duration=duration)
            if not valid and detail.get("limit") is not None and detail.get("used") is not None:
                entry["unavailable_reason"] = "unparsed"
            windows[key] = entry
        if isinstance(holder.get("usage"), dict):
            counter("seven_day", holder["usage"], 10080)
        for value in holder.get("limits", []):
            descriptor = obj(obj(value).get("window"))
            duration = descriptor.get("duration")
            if descriptor.get("timeUnit") != "TIME_UNIT_MINUTE" or type(duration) is not int or duration <= 0:
                raise Unavailable("unparsed")
            counter({300: "five_hour", 10080: "seven_day"}.get(duration, "rolling:" + str(duration) + "m"), value.get("detail"), duration)
        return list(windows.values())
    usages = next((v["usages"] for v in holders if isinstance(v, dict) and isinstance(v.get("usages"), dict)), None)
    if usages is None:
        raise Unavailable("vendor_usage_unavailable")
    windows = []
    for key, value in usages.items():
        if not isinstance(value, dict):
            continue
        ratio = value.get("used_ratio", value.get("usedRatio"))
        valid = type(ratio) in (int, float) and math.isfinite(ratio) and 0 <= ratio <= 1
        key = {"limit_5h": "five_hour", "limit5h": "five_hour", "limit_7d": "seven_day", "limit7d": "seven_day"}.get(key, key)
        reset = value.get("reset_time", value.get("resetTime", value.get("reset_at", value.get("resetAt"))))
        entry = window(key, "default", ratio * 100 if valid else None, observed, reset=reset)
        if not valid and ratio is not None:
            entry["unavailable_reason"] = "unparsed"
        windows.append(entry)
    return windows


def _bounded_stdout(argv, env, timeout, input=None):
    completed = run_bounded(argv, env, env.get("HOME"), timeout, input)
    if completed.error == TIMEOUT:
        raise Unavailable("source_timeout")
    if completed.error is not None:
        raise Unavailable()
    return completed.stdout


def rpc(argv, env, initialize, calls, *, initialized=False, timeout=35):
    """Return one result per call; a call answered with a JSON-RPC error is None.

    Each request waits for its response. Server requests are never serviced,
    including elicitation/tool calls.
    """
    try:
        with interactive_bounded(argv, env, env.get("HOME"), timeout) as session:
            def send(message):
                session.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")

            def answer(identifier, during_initialize=False):
                while True:
                    line = session.readline(limit=65536)
                    if not line:
                        raise Unavailable()
                    message = obj(json.loads(line))
                    if "method" in message and "id" in message:
                        raise Unavailable("unparsed")
                    if message.get("id") != identifier:
                        continue
                    if message.get("error") is not None:
                        if during_initialize:
                            raise Unavailable("vendor_usage_unavailable")
                        return None
                    return obj(message.get("result"))

            send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": initialize})
            answer(1, during_initialize=True)
            if initialized:
                send({"jsonrpc": "2.0", "method": "initialized"})
            answers = []
            for identifier, (method, params) in enumerate(calls, 2):
                send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
                answers.append(answer(identifier))
            session.close_stdin()
            return answers
    except BoundedError as exc:
        raise Unavailable(exc.code) from None


def http_json(url, headers, *, method="GET", timeout=8, rejected=None):
    request = urllib.request.Request(url, headers=headers, method=method, data=b"" if method == "POST" else None)
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), helper.NoRedirect()).open(request, timeout=timeout) as response:
            raw = response.read(helper.MAX_BYTES + 1)
    except urllib.error.HTTPError as exc:
        # Callers that can tell an expired token (401) from a refused one (403)
        # pass their own mapping; loopback reads treat both as no login.
        codes = rejected or {401: "local_login_unavailable", 403: "local_login_unavailable"}
        raise Unavailable(codes.get(exc.code, "source_usage_unavailable")) from None
    except urllib.error.URLError as exc:
        raise Unavailable("source_timeout" if isinstance(exc.reason, TimeoutError) else "source_usage_unavailable") from None
    if len(raw) > helper.MAX_BYTES:
        raise Unavailable("unparsed")
    return obj(json.loads(raw)) if raw else {}


def kimi(env, io, command=None):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = dict(env, KIMI_CODE_NO_AUTO_UPDATE="1")
    pattern = re.compile(rb"(http://127\.0\.0\.1:" + str(port).encode() +
                         rb")/#token=([A-Za-z0-9_.~-]+)")
    try:
        with interactive_bounded([command or "kimi", "web", "--no-open", "--port", str(port)],
                                 env, env.get("HOME"), 40) as session:
            base = headers = None
            while base is None:
                line = session.readline(limit=65536)
                if not line:
                    raise Unavailable()
                match = pattern.search(line)
                if match:
                    base = match[1].decode("ascii")
                    key = match[2].decode("ascii")
                    io._remember({"server_token": key})
                    headers = {"Authorization": "Bearer " + key, "Accept": "application/json"}
            try:
                account = http_json(base + "/api/v1/oauth/userinfo", headers)
                quota = http_json(base + "/api/v1/oauth/usage", headers)
                return account, quota
            finally:
                try:
                    http_json(base + "/api/v1/shutdown", headers, method="POST", timeout=2)
                except Exception:
                    pass
    except BoundedError as exc:
        raise Unavailable(exc.code) from None


def _claude_config_directory(home, env):
    value = os.path.expanduser(os.fspath(env.get("CLAUDE_CONFIG_DIR") or home / ".claude"))
    return unicodedata.normalize("NFC", os.path.normpath(os.path.abspath(value)))


def _keychain_account():
    try:
        username = getpass.getuser()
    except (KeyError, OSError):
        username = ""
    return username if re.fullmatch(r"[A-Za-z0-9._-]{1,255}", username) else "claude-code-user"


def _keychain_credentials(home, env, io):
    config = _claude_config_directory(home, env)
    default = _claude_config_directory(home, {})
    service = "Claude Code-credentials"
    if config != default:
        service += "-" + hashlib.sha256(config.encode("utf-8")).hexdigest()[:8]
    completed = run_bounded(
        ["/usr/bin/security", "find-generic-password", "-a", _keychain_account(),
         "-s", service, "-w"], env, env.get("HOME"), 5)
    if completed.status == 44:
        return None
    if completed.error == TIMEOUT:
        raise Unavailable("source_timeout")
    if completed.error is not None:
        # A locked or denied Keychain is not a missing login. Never unlock it,
        # invoke a GUI, change its ACL, or bypass consent with another item.
        raise Unavailable("local_login_unavailable")
    try:
        document = json.loads(completed.stdout)
    except (ValueError, UnicodeError):
        raise helper.SafeError("Source profile JSON is invalid") from None
    io._remember(document)
    return document


def _claude_credentials(home, env, io):
    document = _keychain_credentials(home, env, io) if sys.platform == "darwin" else None
    if document is None:
        config = _claude_config_directory(home, env)
        try:
            document = io.read_json(Path(config) / ".credentials.json")
        except FileNotFoundError:
            raise Unavailable("local_login_unavailable") from None
    return obj(document)


def _principal(value, *, plan=None, organization_id=None):
    value = name(value)
    result = {"principal": value, "principal_kind": "email" if "@" in value else "id", "label": value}
    if plan:
        result["plan"] = plan
    if organization_id:
        result["organization_id"] = organization_id
    return result


def collect(provider, home, env, io, command=None):
    from metadata_providers import collect as metadata, collect_usage
    observed = int(time.time() * 1000)
    credit_balance = None
    if provider == "claude":
        # `claude auth status` runs first so a token the CLI renews on the way
        # is the one read from the selected store. A signed-out CLI exits nonzero,
        # so its failure is held until missing and expired credentials have been
        # classified; unreadable/malformed files and command failures keep their
        # non-auth errors.
        account = status_failure = None
        try:
            account = metadata(provider, home, env, io)
        except Exception as exc:
            status_failure = exc
        credentials = _claude_credentials(home, env, io)
        oauth = obj(credentials.get("claudeAiOauth"))
        token = oauth.get("accessToken")
        if not isinstance(token, str) or not token or not token.isprintable():
            raise Unavailable("local_login_unavailable")
        # An expired access token is never refreshed or sent; Claude renews it
        # itself. The access token lives hours, the login (its refresh token)
        # weeks, and a running Claude can keep renewing in memory while the
        # saved copy stays stale. So a stale access token is "login expired"
        # only when the login has ended too: no refresh token, or its own
        # refreshTokenExpiresAt has passed (SKILLS-217).
        # Both stamps are read in milliseconds; a positive value below 1e11 is
        # taken as seconds (1e11 ms is 1973, 1e11 s is year 5138). A refresh
        # expiry that is present but not a finite number, or a blank refresh
        # token, fails closed: the login counts as ended, never as valid.
        now = time.time() * 1000
        expires = _epoch_ms(oauth.get("expiresAt"))
        if expires is not None and expires <= now:
            refresh = oauth.get("refreshToken")
            # Only a missing key means "expiry unknown"; an explicit null is a
            # present but invalid value and fails closed.
            refresh_expires = _epoch_ms(oauth.get("refreshTokenExpiresAt"))
            login_live = isinstance(refresh, str) and refresh.strip() != "" and (
                "refreshTokenExpiresAt" not in oauth or (refresh_expires is not None and refresh_expires > now))
            raise Unavailable("access_token_stale" if login_live else "web_login_expired")
        if status_failure is not None:
            raise status_failure
        document = http_json("https://api.anthropic.com/api/oauth/usage",
                             {"Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"},
                             rejected={401: "web_login_expired", 403: "web_login_forbidden"})
        windows = parse_claude(document, observed)
    elif provider == "openai":
        def read_codex(refresh):
            return rpc([command or "codex", "app-server", "--stdio"], env,
                {"clientInfo": {"name": "usage", "version": "1"}, "capabilities": {"experimentalApi": True}},
                [("account/read", {"refreshToken": refresh}), ("account/rateLimits/read", {"excludeResetCreditDetails": True})], initialized=True)
        login, quota = read_codex(False)
        # An expired access token reads as signed out. With a saved login,
        # Codex gets one chance to renew it through its own refresh flow, the
        # one the CLI runs on a 401: it reloads auth.json first, so a token
        # another Codex process just renewed is reused rather than replaced.
        saved_login = (Path(env.get("CODEX_HOME") or home / ".codex") / "auth.json").is_file()
        if login is not None and login.get("account") is None and saved_login:
            login, quota = read_codex(True)
        if login is None:
            raise Unavailable("vendor_usage_unavailable")
        if login.get("account") is None:
            # Still signed out after Codex's own renewal: a saved login it
            # could not renew has expired; without one there is no login.
            raise Unavailable("web_login_expired" if saved_login else "local_login_unavailable")
        login = obj(login["account"])
        if login.get("type") != "chatgpt":
            # API-key auth is a login, but it has no ChatGPT subscription allowance.
            raise Unavailable("api_key_login")
        if quota is None:
            raise Unavailable("vendor_usage_unavailable")
        # accountId is the ChatGPT workspace shared by every member of a team;
        # it is never the principal. Without an email the reading stays unlinked.
        account = None
        if login.get("email"):
            account = _principal(login["email"], plan=login.get("planType"))
            if quota.get("accountId"):
                account["workspace_id"] = quota["accountId"]
        windows = parse_codex(quota, observed)
        credit_balance = codex_credit_balance(quota)
    elif provider == "antigravity":
        raw = _bounded_stdout([command or "agy", "--print", "/usage", "--print-timeout", "45s"], env, 50)
        windows = parse_agy(raw.decode("utf-8"), observed)
        account = metadata(provider, home, env, io)
    elif provider == "grok":
        subscription, quota = rpc([command or "grok", "agent", "stdio"], env,
            {"protocolVersion": 1, "clientCapabilities": {}},
            [("_x.ai/auth/check_subscription", {}), ("_x.ai/billing", {})])
        if subscription is None:
            raise Unavailable("vendor_usage_unavailable")
        if subscription.get("authenticated") is not True:
            raise Unavailable("local_login_unavailable")
        if quota is None:
            raise Unavailable("vendor_usage_unavailable")
        # team_id is shared by a whole team; it is never the principal.
        meta = obj(subscription.get("meta", {}))
        account = None
        if meta.get("email"):
            account = _principal(meta["email"], plan=meta.get("subscription_tier"), organization_id=meta.get("team_id"))
        windows = parse_grok(quota, observed)
    elif provider == "kimi":
        account, quota = kimi(env, io, command)
        data = account.get("data", {})
        candidates = [account.get("userInfo"), account.get("user_info"), data.get("userInfo") if isinstance(data, dict) else None,
                      data.get("user_info") if isinstance(data, dict) else None, data, account]
        holder = next((v for v in candidates if isinstance(v, dict) and ("userId" in v or "user_id" in v)), {})
        account = _principal(holder.get("user_id", holder.get("userId")), plan=holder.get("user_level_name", holder.get("userLevelName")))
        windows = parse_kimi(quota, observed)
    elif provider == "muse":
        quota = collect_usage(provider, home, env, io)
        try:
            account = metadata(provider, home, env, io)
        except (ValueError, helper.SafeError):
            # A cold CLI can honestly report awaiting-turn before its own
            # credential cache has enough account fields for canonical identity.
            account = None
        return account, quota
    else:
        raise Unavailable("source_profile_invalid")
    return account, {"provider": provider, "windows": windows, "observed_at_ms": observed,
                     **({"credit_balance": credit_balance} if credit_balance is not None else {}),
                     **({"unavailable_reason": "not_reported"} if not windows else {})}


def handle(envelope):
    request = helper.validate_request(envelope["request"])
    selectors = helper.validate_selectors(request["kind"], envelope["selectors"])
    response = {"version": 1, **helper.source_identity()}
    try:
        home = helper.current_home()
        env = helper.profile_environment(request["kind"], home, selectors)
        env["USAGE_SOURCE_KIND"] = request["kind"]
        io = helper.SourceIO(home, env, request.get("command"))
        metadata, usage = collect(request["provider"], home, env, io, request.get("command"))
        if metadata is not None:
            response["metadata"] = helper.project_metadata(metadata, io.secrets)
        response["usage"] = helper.project_usage(usage, io.secrets)
    except Unavailable as exc:
        response["error"] = exc.code
    except TimeoutError:
        response["error"] = "source_timeout"
    except (json.JSONDecodeError, UnicodeDecodeError):
        response["error"] = "unparsed"
    except Exception:
        # Never serialize exceptions: URLs, stdout and parser errors can hold secrets.
        response["error"] = "source_usage_unavailable"
    return response
