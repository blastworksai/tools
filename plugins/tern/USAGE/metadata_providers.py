"""Account metadata for Claude, Antigravity and Muse, and Muse's CLI usage report.

Claude's supported auth-status JSON supplies its own selected account.
Antigravity's cached Google token is checked against Google userinfo. Muse's
persisted OAuthTokens supply cached account fields; absent subscription tiers
stay unknown. Muse's key endpoint is a key exchange, not a read-only metadata
request, so it is never called. collect_usage projects only the supported
`muse usage --json` output; it never substitutes a direct provider quota
request or a model turn. The caller must prove the exact source context.
"""

from datetime import datetime
import math
from pathlib import Path
import re
import time


UNKNOWN = "Provider account metadata unavailable for this source context"
USAGE_UNKNOWN = "Muse usage unavailable for this source context"
_EMAIL = re.compile(r"[A-Za-z0-9.!#$%&'+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z0-9-]+")
_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,255}")


def _unknown():
    raise ValueError(UNKNOWN)


def _object(value):
    if not isinstance(value, dict):
        _unknown()
    return value


def _text(value):
    if not isinstance(value, str) or not value or len(value) > 256:
        _unknown()
    if value != value.strip() or any(ord(c) < 32 or ord(c) == 127 for c in value):
        _unknown()
    return value


def _email(value):
    value = _text(value)
    if not _EMAIL.fullmatch(value) or ".." in value:
        _unknown()
    return value


def _id(value):
    value = _text(value)
    if not _ID.fullmatch(value):
        _unknown()
    return value


def _optional(result, document, source, target, parser=_text):
    value = document.get(source)
    if value is not None:
        result[target] = parser(value)


def _claude(home, env, io):
    # Refuse token/API modes before invoking the CLI, not after reading a
    # different cached login. The command itself selects Claude's OAuth storage.
    if any(env.get(key) for key in (
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
        "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    )):
        _unknown()
    document = _object(io.run_json(["claude", "auth", "status", "--json"], env))
    if (document.get("loggedIn") is not True
            or document.get("authMethod") != "claude.ai"
            or document.get("apiProvider", "firstParty") != "firstParty"):
        _unknown()
    config = document.get("configDirectory")
    expected = Path(env.get("CLAUDE_CONFIG_DIR") or home / ".claude")
    if config is not None and Path(_text(config)) != expected:
        _unknown()
    principal = _email(document.get("email"))
    result = {"principal": principal, "principal_kind": "email", "label": principal}
    _optional(result, document, "orgId", "organization_id", _id)
    _optional(result, document, "orgName", "organization")
    _optional(result, document, "subscriptionType", "plan")
    return result


def _bearer(value):
    if not isinstance(value, str) or not value or len(value) > 65536:
        _unknown()
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        _unknown()
    return value


def _future(value, divisor=1):
    if type(value) not in (int, float) or not value / divisor > time.time():
        _unknown()


def _google_identity(token, io):
    document = _object(io.request_json(
        "https://www.googleapis.com/oauth2/v2/userinfo",
        {"Authorization": "Bearer " + _bearer(token), "Accept": "application/json"}))
    # Google userinfo v2 names the stable subject `id`, not OIDC `sub`.
    subject = _id(document.get("id"))
    address = document.get("email")
    if address is not None:
        principal, kind = _email(address), "email"
        if document.get("verified_email") is not True:
            _unknown()
    else:
        principal, kind = subject, "id"
    return {"principal": principal, "principal_kind": kind, "label": principal}


def _antigravity(home, env, io):
    if any(env.get(key) for key in ("AGY_ADC_AUTH", "GOOGLE_APPLICATION_CREDENTIALS", "AGY_ACCOUNT")):
        _unknown()
    document = _object(io.read_json(
        home / ".gemini/antigravity-cli/antigravity-oauth-token"))
    token = _object(document.get("token"))
    if token.get("token_type", "Bearer") != "Bearer":
        _unknown()
    if token.get("expiry") is not None:
        expiry = datetime.fromisoformat(_text(token["expiry"]).replace("Z", "+00:00"))
        if expiry.tzinfo is None:
            _unknown()
        _future(expiry.timestamp())
    # No CLI /usage call: it can refresh and persist credentials. Userinfo
    # rejects expired tokens without changing them; it does not report a tier.
    return _google_identity(token.get("access_token"), io)


def _muse(home, env, io):
    if any(env.get(key) for key in ("META_API_KEY", "MUSE_API_KEY", "MUSE_ACCESS_TOKEN", "MUSE_AUTH_PATH")):
        _unknown()
    root = Path(env.get("XDG_CONFIG_HOME") or home / ".config")
    if not root.is_absolute():
        _unknown()
    document = _object(io.read_json(root / "muse/auth.json"))
    if document.get("schema_version", 1) != 1:
        _unknown()
    meta = _object(_object(document.get("providers")).get("meta"))
    # Muse's OAuthTokens stores the model API key alongside cached identity.
    # expires_at belongs to its web OAuth access token, not this code key or
    # the email association. Do not discard identity solely for OAuth expiry.
    _bearer(meta.get("api_key"))
    principal = _email(meta.get("user_email"))
    result = {"principal": principal, "principal_kind": "email", "label": principal}
    _optional(result, meta, "user_full_name", "label")
    # Corroborate the selected Muse profile without a key exchange/refresh.
    # SourceIO memoizes this exact command per request, so the separate quota
    # projection reuses it rather than spawning a second CLI process.
    usage = collect_usage("muse", home, env, io)
    if not usage["windows"] and usage.get("unavailable_reason") != "server_sent_no_usage":
        _unknown()
    # subs_active is a boolean, not a plan. Neither it nor an API key can
    # establish a subscription tier, and /muse-code/key can mint credentials.
    return result


def collect(provider: str, home: Path, env: dict[str, str], io) -> dict:
    """Return only allowlisted fields, or a fixed safe unknown error.

    IO provides bounded read_json, run_json and pinned read-only request_json.
    """
    try:
        expected_kind = {"claude": "claude", "antigravity": "agy", "muse": "muse"}.get(provider)
        if expected_kind is None or env.get("USAGE_SOURCE_KIND") != expected_kind:
            _unknown()
        if env.get("HOME") and Path(env["HOME"]) != home:
            _unknown()
        if provider == "claude":
            return _claude(home, env, io)
        if provider == "antigravity":
            return _antigravity(home, env, io)
        return _muse(home, env, io)
    except Exception:
        # IO and decoders can include token-bearing data in their exception
        # messages. Never propagate their text, repr, traceback chain, or body.
        raise ValueError(UNKNOWN) from None


def _usage_timestamp(value):
    if type(value) is not int or not 1_000_000_000_000 <= value <= 4_102_444_800_000:
        _unknown()
    return value


def _usage_window(document, key, observed_at_ms):
    document = _object(document)
    used = document.get("usedPercent")
    if type(used) not in (int, float) or not math.isfinite(used) or not 0 <= used <= 100:
        _unknown()
    result = {"key": key, "pool": "default", "used": used,
              "remaining": 100 - used, "observed_at_ms": observed_at_ms}
    if document.get("resetsAtMs") is not None:
        result["resets_at_ms"] = _usage_timestamp(document["resetsAtMs"])
    return result


def collect_usage(provider: str, home: Path, env: dict[str, str], io) -> dict:
    """Project Muse's schemaVersion=1 CLI report, not internal serde fields.

    Cached allowance has asOfMs and window/weekly usedPercent/resetsAtMs.
    Reading it cannot advance the measurement time. A missing allowance is not
    zero usage; obtaining one requires a real turn outside this integration.
    """
    try:
        if provider != "muse" or env.get("USAGE_SOURCE_KIND") != "muse":
            _unknown()
        if env.get("HOME") and Path(env["HOME"]) != home:
            _unknown()
        if any(env.get(key) for key in ("META_API_KEY", "MUSE_API_KEY", "MUSE_ACCESS_TOKEN", "MUSE_AUTH_PATH")):
            _unknown()
        config = Path(env.get("XDG_CONFIG_HOME") or home / ".config")
        if not config.is_absolute():
            _unknown()
        # SourceIO forces the documented MUSE_NO_AUTO_UPDATE=1 launcher flag
        # for this exact command; all source profile/auth environment is kept.
        document = _object(io.run_json(["muse", "usage", "--json"], env))
        if type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
            _unknown()
        if "allowance" not in document:
            _unknown()
        observed = int(time.time() * 1000)
        result = {"provider": "muse", "windows": [], "observed_at_ms": observed}
        allowance = document["allowance"]
        if allowance is None:
            result["unavailable_reason"] = ("server_sent_no_usage"
                                            if document.get("reason") == "server_sent_no_usage"
                                            else "unavailable")
            return result
        allowance = _object(allowance)
        observed = _usage_timestamp(allowance.get("asOfMs"))
        result["observed_at_ms"] = observed
        if allowance.get("window") is not None:
            result["windows"].append(_usage_window(allowance["window"], "rolling", observed))
        if allowance.get("weekly") is not None:
            result["windows"].append(_usage_window(allowance["weekly"], "seven_day", observed))
        _optional(result, allowance, "tier", "plan")
        if not result["windows"]:
            result["unavailable_reason"] = "unavailable"
        return result
    except Exception:
        raise ValueError(USAGE_UNKNOWN) from None
