"""Bounded JSON ingress and allowlisted v3 snapshots shared with snapshot.luau.

Invalid input is rejected without changing durable state. Public errors are fixed
codes/messages: never include the rejected value, a path, or an exception string.
Provider parsing and account reduction belong exclusively to Luau.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from typing import Any
from uuid import UUID

PROTOCOL = 1
MAX_BODY = 1_048_576
MAX_READINGS = 1000
MAX_WINDOWS = 65
MAX_INTEGER = 9_007_199_254_740_991
CHUNK_BYTES = 65_536
CLIENT_LEASE_SECONDS = 90
REASONS = frozenset({"not_reported", "unparsed", "source_unreachable", "not_yet_measured", "reset_passed", "stale", "web_login_expired", "unavailable", "server_sent_no_usage",
    "local_login_unavailable", "source_metadata_disabled", "vendor_usage_unavailable", "source_timeout",
    "source_context_ambiguous", "source_profile_invalid", "source_profile_unavailable", "source_usage_unavailable",
    "source_remote", "api_key_login", "web_login_forbidden"})
# Readings written by pre-2.0 builds carry these usage_source values.
LEGACY_USAGE_SOURCES = {"native-headless": "headless", "native-passive:last-good": "last-good"}
MESSAGES = {
    "snapshot_rejected": "The snapshot was rejected.",
    "snapshot_too_large": "The snapshot exceeds the configured size limit.",
    "invalid_request": "The request is invalid.",
    "unauthorized": "Authorization is required.",
    "forbidden": "This operation is not authorized.",
    "conflict": "The request conflicts with existing state.",
    "replay": "The publication is older than accepted state.",
    "capacity": "Coverage is incomplete because a configured limit was reached.",
    "not_found": "The requested record is unavailable.",
    "expired": "The request has expired.",
    "web_login_expired": "The provider login has expired. Sign in again with the provider's own CLI.",
    "source_remote": "Runs on another machine over SSH; USAGE reads it only on that machine.",
    "api_key_login": "Signed in with an API key, which has no subscription quota.",
    "web_login_forbidden": "The provider refused this login's usage request. Sign in again with the provider's own CLI to grant usage access.",
    "source_unreachable": "The sharing source is unreachable.",
    "address_in_use": "The sharing port is already in use on this machine.",
    "address_unavailable": "The sharing address is not available on this machine.",
    "bind_failed": "USAGE could not listen on the sharing address.",
    "pin_mismatch": "The sharing certificate does not match the paired identity.",
    "setup_required": "USAGE setup is required.",
    "companion_unavailable": "The local USAGE companion is unavailable.",
    "incompatible_version": "The companion and package versions do not match.",
    "migration_conflict": "Existing installation identities conflict; neither was changed.",
    "internal_error": "USAGE could not complete the operation.",
    "unsupported_tern": "This Tern installation does not support source collection.",
    "source_context_ambiguous": "The source profile cannot be identified unambiguously.",
    "source_capture_too_large": "The current source capture exceeds the size limit.",
    "source_profile_invalid": "The source profile configuration is invalid.",
    "source_profile_unavailable": "The source profile is unavailable.",
    "source_profile_stale": "The source profile changed; confirm its current identity.",
    "source_helper_unverified": "The source helper does not match this installation.",
    "source_metadata_disabled": "Headless usage reads are off; choose Allow headless usage reads in USAGE Setup.",
    "source_roster_invalid": "SPAWN's account list is invalid. Check its configuration in SPAWN.",
    "source_roster_unavailable": "SPAWN's account list could not be read.",
    "local_login_unavailable": "No usable local provider login is available.",
    "vendor_usage_unavailable": "The provider's usage endpoint cannot currently prove this allowance.",
    "source_timeout": "The provider usage read exceeded its deadline.",
    "source_usage_unavailable": "The provider quota is unavailable.",
    "source_configuration_changed": "SPAWN changed during refresh; request a new reading.",
    "export_disabled": "Enable read-only capacity export in USAGE Setup.",
    "export_revoked": "Capacity authorization changed; request a new snapshot after owner approval.",
    "evidence_changed": "Capacity evidence changed; assemble a new complete snapshot.",
    "incomplete": "Assemble every snapshot page before current validation.",
    "binding_unavailable": "This SPAWN account has no current headless reading with a provider identity; refresh, then bind it.",
    "binding_changed": "The SPAWN account or its reading changed; choose Bind SPAWN accounts again.",
}

class ServiceError(Exception):
    def __init__(self, code: str, status: int = 400):
        self.code = code if code in MESSAGES else "internal_error"
        self.status = status
        super().__init__(MESSAGES[self.code])

    def public(self) -> dict[str, Any]:
        return {"ok": False, "error": {"code": self.code, "message": MESSAGES[self.code]}}

@dataclass(frozen=True)
class Authority:
    """Created by authenticated ingress, never from a publication's claims."""
    device_id: str
    group_id: str
    role: str = "member"
    local: bool = False


def encode(value: Any) -> bytes:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError, UnicodeError, RecursionError) as exc:
        raise ServiceError("invalid_request") from exc


def _constant(_: str) -> None:
    raise ServiceError("invalid_request")


def decode(raw: bytes | str, maximum: int = MAX_BODY) -> Any:
    if isinstance(raw, str):
        try:
            raw = raw.encode("utf-8")
        except UnicodeError as exc:
            raise ServiceError("invalid_request") from exc
    if not isinstance(raw, bytes) or len(raw) > maximum:
        raise ServiceError("snapshot_too_large", 413)
    try:
        return json.loads(raw, parse_constant=_constant)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise ServiceError("invalid_request") from exc


def text(value: Any, maximum: int = 1024, *, allow_blank: bool = False) -> str:
    if not isinstance(value, str) or not value or (not allow_blank and not re.search(r"[^ \t\r\n\v\f]", value)) or re.search(r"[\x00-\x1f\x7f]", value):
        raise ServiceError("snapshot_rejected")
    try:
        if len(value.encode("utf-8")) > maximum:
            raise ServiceError("snapshot_rejected")
    except UnicodeError as exc:
        raise ServiceError("snapshot_rejected") from exc
    return value


def integer(value: Any, minimum: int = 0, maximum: int = MAX_INTEGER) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not minimum <= value <= maximum or not math.isfinite(value) or value % 1:
        raise ServiceError("snapshot_rejected")
    return int(value)


def identifier(value: Any) -> str:
    try:
        parsed = UUID(text(value, 36))
        if str(parsed) != value:
            raise ValueError()
    except (ValueError, AttributeError) as exc:
        raise ServiceError("invalid_request") from exc
    return str(parsed)


def _list(value: Any, maximum: int) -> list[Any]:
    # Luau tables cannot distinguish an empty untagged object from an empty list.
    if isinstance(value, dict) and not value:
        return []
    if not isinstance(value, list) or len(value) > maximum:
        raise ServiceError("snapshot_rejected")
    return value


def _window(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ServiceError("snapshot_rejected")
    result = {"key": text(raw.get("key"), 128), "pool": text(raw.get("pool"), 128), "observed_at_ms": integer(raw.get("observed_at_ms"))}
    reason = raw.get("unavailable_reason")
    if reason is not None:
        if not isinstance(reason, str) or reason not in REASONS or raw.get("used") is not None or raw.get("remaining") is not None:
            raise ServiceError("snapshot_rejected")
        result["unavailable_reason"] = reason
    else:
        for key in ("used", "remaining"):
            value = raw.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 100 or not math.isfinite(value):
                raise ServiceError("snapshot_rejected")
            result[key] = value
        if abs(result["remaining"] - (100 - result["used"])) > 0.000001:
            raise ServiceError("snapshot_rejected")
    for key in ("resets_at_ms", "reset_observed_at_ms"):
        if raw.get(key) is not None:
            result[key] = integer(raw[key])
    if raw.get("window_duration_mins") is not None:
        result["window_duration_mins"] = integer(raw["window_duration_mins"], 1, 525600)
    if raw.get("last_known_reason") is not None:
        reason = raw["last_known_reason"]
        if not isinstance(reason, str) or reason not in REASONS or "used" not in result or "unavailable_reason" in result:
            raise ServiceError("snapshot_rejected")
        result["last_known_reason"] = reason
    if raw.get("reset_label") is not None:
        result["reset_label"] = text(raw["reset_label"])
    if raw.get("reset_calendar") is not None:
        calendar = raw["reset_calendar"]
        if not isinstance(calendar, dict):
            raise ServiceError("snapshot_rejected")
        bounds = {"year": (1970, 2100), "month": (1, 12), "day": (1, 31), "hour": (0, 23), "minute": (0, 59)}
        projected = {k: integer(calendar[k], *b) for k, b in bounds.items() if calendar.get(k) is not None}
        if "hour" not in projected or "minute" not in projected:
            raise ServiceError("snapshot_rejected")
        if calendar.get("timezone") is not None:
            projected["timezone"] = text(calendar["timezone"], 128, allow_blank=True)
        result["reset_calendar"] = projected
    return result


def _reading(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ServiceError("snapshot_rejected")
    result = {k: text(raw.get(k), size) for k, size in (("id",4096), ("provider",128), ("provider_label",1024), ("source_label",1024), ("usage_source",1024))}
    result["usage_source"] = LEGACY_USAGE_SOURCES.get(result["usage_source"], result["usage_source"])
    if (raw.get("account_id") is None) != (raw.get("account_label") is None):
        raise ServiceError("snapshot_rejected")
    for key, size in (("agent_id",4096), ("agent_label",1024), ("account_id",4096), ("account_label",1024), ("canonical_id",4096), ("principal_id",4096), ("plan",1024)):
        if raw.get(key) is not None:
            result[key] = text(raw[key], size)
    if raw.get("account_aliases") is not None:
        if "canonical_id" not in result:
            raise ServiceError("snapshot_rejected")
        result["account_aliases"] = [text(v,4096,allow_blank=True) for v in _list(raw["account_aliases"],27)]
    if raw.get("last_reading_at_ms") is not None:
        result["last_reading_at_ms"] = integer(raw["last_reading_at_ms"])
    if raw.get("credit_balance") is not None:
        balance = raw["credit_balance"]
        if type(balance) not in (int, float) or not 0 <= balance <= MAX_INTEGER or not math.isfinite(balance):
            raise ServiceError("snapshot_rejected")
        result["credit_balance"] = balance
    windows = [_window(v) for v in _list(raw.get("windows"),MAX_WINDOWS)]
    result["windows"] = [w for w in windows if not (result["provider"] == "claude" and w["key"] in ("iguana_necktie", "nimbus_quill"))]
    return result


def _binding_fields(raw, result, evidence):
    """Accounts may carry `profile_binding`; consumers may carry `account_ids`."""
    other = "account_ids" if evidence == "profile_binding" else "profile_binding"
    if raw.get(other) is not None:
        raise ServiceError("snapshot_rejected")
    if raw.get("definition_revision") is not None:
        revision = text(raw["definition_revision"], 64)
        if not re.fullmatch(r"[0-9a-f]{64}", revision):
            raise ServiceError("snapshot_rejected")
        result["definition_revision"] = revision
    if raw.get("profile_binding") is not None:
        binding = raw["profile_binding"]
        if not isinstance(binding, dict) or set(binding) != {"handle", "generation", "canonical_ids"}:
            raise ServiceError("snapshot_rejected")
        ids = [text(value, 4096) for value in _list(binding["canonical_ids"], 32)]
        if not ids or "definition_revision" not in result:
            raise ServiceError("snapshot_rejected")
        result["profile_binding"] = {"handle": text(binding["handle"], 256),
                                     "generation": integer(binding["generation"], 1), "canonical_ids": ids}
    if raw.get("account_ids") is not None:
        # Owner-declared: the bound account whose quota this consumer record uses.
        ids = [text(value, 4096) for value in _list(raw["account_ids"], 1)]
        if not ids or "definition_revision" not in result:
            raise ServiceError("snapshot_rejected")
        result["account_ids"] = ids


def _roster(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict) or isinstance(raw.get("version"), bool) or raw.get("version") != 1:
        raise ServiceError("snapshot_rejected")
    scopes, seen = [], set()
    for scope in _list(raw.get("scopes"), 128):
        if not isinstance(scope, dict):
            raise ServiceError("snapshot_rejected")
        scope_id = text(scope.get("id"), 512)
        if scope_id in seen:
            raise ServiceError("snapshot_rejected")
        seen.add(scope_id)
        entries, consumers, members = [], [], set()
        for entry in _list(scope.get("accounts"), 1000):
            if not isinstance(entry, dict):
                raise ServiceError("snapshot_rejected")
            item = {key: text(entry.get(key), size) for key, size in
                    (("id", 4096), ("provider", 256), ("provider_label", 1024), ("account_label", 1024))}
            if item["id"] in members:
                raise ServiceError("snapshot_rejected")
            members.add(item["id"])
            for key in ("canonical_ids", "reading_ids"):
                item[key] = [text(value, 4096) for value in _list(entry.get(key), 1000)]
            _binding_fields(entry, item, "profile_binding")
            entries.append(item)
        for consumer in _list(scope.get("consumers"), 1000):
            if not isinstance(consumer, dict):
                raise ServiceError("snapshot_rejected")
            item = {"id": text(consumer.get("id"), 4096), "label": text(consumer.get("label"), 1024),
                    "reading_ids": [text(value, 4096) for value in _list(consumer.get("reading_ids"), 1000)]}
            if item["id"] in members:
                raise ServiceError("snapshot_rejected")
            members.add(item["id"])
            _binding_fields(consumer, item, "account_ids")
            consumers.append(item)
        normalized = {"id": scope_id, "revision": text(scope.get("revision"), 512),
                      "updated_at_ms": integer(scope.get("updated_at_ms")),
                      "accounts": entries, "consumers": consumers}
        if scope.get("spawn_join") is not None:
            join = scope["spawn_join"]
            if not isinstance(join, dict) or set(join) != {"namespace", "host_key", "config_revision"}:
                raise ServiceError("snapshot_rejected")
            normalized["spawn_join"] = {"namespace": text(join["namespace"], 512),
                                        "host_key": text(join["host_key"], 512),
                                        "config_revision": integer(join["config_revision"])}
        scopes.append(normalized)
    return {"version": 1, "scopes": scopes}


def validate_snapshot(raw: Any) -> dict[str, Any]:
    if isinstance(raw, (str, bytes)):
        raw = decode(raw)
    if len(encode(raw)) > MAX_BODY:
        raise ServiceError("snapshot_too_large",413)
    if not isinstance(raw, dict) or isinstance(raw.get("version"), bool) or raw.get("version") != 3:
        raise ServiceError("snapshot_rejected")
    result = {"version":3, "publisher":text(raw.get("publisher"),512), "as_of_ms":integer(raw.get("as_of_ms")), "readings":[_reading(v) for v in _list(raw.get("readings"),MAX_READINGS)]}
    if raw.get("roster") is not None:
        result["roster"] = _roster(raw["roster"])
    return result


def validate_publication(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict) or raw.get("protocol") != PROTOCOL or isinstance(raw.get("protocol"),bool):
        raise ServiceError("invalid_request")
    result: dict[str, Any] = {"protocol": PROTOCOL}
    for key in ("observer_device_id", "subject_source_id", "epoch", "generation"):
        result[key] = identifier(raw.get(key))
    result["publisher"] = text(raw.get("publisher"),512)
    result["sequence"] = integer(raw.get("sequence"),1)
    result["profile_generation"] = integer(raw.get("profile_generation"))
    kind = raw.get("kind")
    if kind not in ("passive", "inventory"):
        raise ServiceError("invalid_request")
    result["kind"] = kind
    if raw.get("profile_handles") is not None:
        result["profile_handles"] = [text(v,256) for v in _list(raw["profile_handles"],32)]
    result["snapshot"] = validate_snapshot(raw.get("snapshot"))
    if result["snapshot"]["publisher"] != result["publisher"]:
        raise ServiceError("forbidden",403)
    if raw.get("lease_id") is not None or raw.get("window_id") is not None:
        raise ServiceError("invalid_request")
    if len(encode(result)) > MAX_BODY:
        raise ServiceError("snapshot_too_large",413)
    return result


def digest(value: Any) -> str:
    return hashlib.sha256(encode(value)).hexdigest()
