"""Read this machine's SPAWN roster; never persist a second account inventory.

SPAWN keeps its live roster in its kv key ``authority``. Only this execution
host's bucket, ``authority.config.hosts[authority.host_key]``, is read. SPAWN's
top-level ``config`` key is its pre-migration original and goes stale, so it is
ignored. Commands, execution users and profile selectors stay on this machine.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

from provider_metadata import SafeError, source_identity
from usage_service.protocol import ServiceError

PROVIDERS = {"claude": "claude", "codex": "openai", "openai": "openai",
             "agy": "antigravity", "antigravity": "antigravity", "kimi": "kimi",
             "muse": "muse", "grok": "grok", "omp": "omp"}
LOCAL_SCOPES = {"host:local", "host:localhost"}
# SPAWN launch/UI choices do not change account membership or profile selection.
# Keep all other fields, including future selectors, in the semantic definition.
LAUNCH_OPTIONS = {"enabled", "include_all", "duplicate_policy", "placement", "prompt",
                  "review_required", "review_reason"}
AUTHORITY_VERSION = 3
MAX_RECORDS = 128


def provider(value):
    key = value.strip().lower()
    return PROVIDERS.get(key, key)


def _invalid():
    return ServiceError("source_roster_invalid", 409)


def _text(value, maximum=1024):
    """The roster.luau text() rule: nonblank, <= maximum UTF-8 bytes, no control characters (incl. DEL)."""
    if not isinstance(value, str) or not value.strip(" ") or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise _invalid()
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError:
        raise _invalid() from None
    if size > maximum:
        raise _invalid()
    return value


def _array(value):
    # Tern serializes an empty Luau table as either [] or {}.
    if value == {}:
        return []
    if not isinstance(value, list):
        raise _invalid()
    return value


def _arguments(value):
    arguments = _array([] if value is None else value)
    if any(not isinstance(item, str) or "\0" in item for item in arguments):
        raise _invalid()
    return arguments


def _definition(record, account_label):
    """Fingerprint account semantics without emitting source-local selectors."""
    definition = {key: value for key, value in record.items() if key not in LAUNCH_OPTIONS}
    definition["account_label"] = account_label
    definition["arguments"] = _arguments(record.get("arguments"))
    return definition


def _uid(user):
    if os.name != "posix":
        return None
    import pwd
    try:
        return str(pwd.getpwnam(user).pw_uid)
    except KeyError:
        return None


def _local_uid(record, current_identity):
    # Device provenance is not subscription identity. Resolve the declared user
    # locally; never borrow a different user's context.
    user = record.get("user")
    if user is None or user == "":
        return current_identity.get("source_uid")
    if not isinstance(user, str):
        return None
    if user in (current_identity.get("source_uid"), current_identity.get("source_user")):
        return current_identity.get("source_uid")
    return _uid(user)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode()).hexdigest()


def read_roster(path, installation_id):
    """Read SPAWN on every pass; return ``(wire roster, local definitions)``.

    ``path`` is SPAWN's sibling kv.json, never a USAGE setting. The roster has
    one scope: this machine's SPAWN bucket. Local definitions carry the
    source-local fields refresh needs and never leave this machine.
    """
    installation_id = _text(installation_id)
    try:
        with Path(path).open("rb") as stream:
            raw = stream.read(1048577)
            updated_at_ms = os.fstat(stream.fileno()).st_mtime_ns // 1000000
        if len(raw) > 1048576:
            raise _invalid()
        saved = json.loads(raw)
    except FileNotFoundError:
        return {"version": 1, "scopes": []}, []
    except (OSError, ValueError):
        raise ServiceError("source_roster_unavailable", 409) from None
    if not isinstance(saved, dict):
        raise _invalid()
    if "authority" not in saved:
        # SPAWN has not opened on this machine yet: no configured accounts.
        return {"version": 1, "scopes": []}, []
    authority = saved["authority"]
    if (not isinstance(authority, dict) or type(authority.get("version")) is not int
            or authority["version"] != AUTHORITY_VERSION):
        raise _invalid()
    host_key = _text(authority.get("host_key"))
    config = authority.get("config")
    if (not isinstance(config, dict) or type(config.get("schema")) is not int or config["schema"] != 2
            or not isinstance(config.get("hosts"), dict)):
        raise _invalid()
    bucket = config["hosts"].get(host_key)
    if not isinstance(bucket, dict) or type(bucket.get("schema")) is not int or bucket["schema"] != 2:
        raise _invalid()
    records = _array(bucket.get("agents"))
    if len(records) > MAX_RECORDS:
        raise _invalid()
    try:
        current_identity = source_identity()
    except (SafeError, KeyError, OSError):
        current_identity = {}
    scope_id = _text(installation_id + ":" + host_key if host_key.lower() in LOCAL_SCOPES else host_key, 512)
    scope = {"id": scope_id, "updated_at_ms": updated_at_ms, "accounts": [], "consumers": []}
    seen, definitions, local = set(), [], []
    for record in records:
        if not isinstance(record, dict):
            raise _invalid()
        identifier = _text(record.get("id"))
        if identifier in seen:
            raise _invalid()
        seen.add(identifier)
        label = _text(record.get("provider"))
        normalized = _text(provider(label), 256)
        account_label = _text(record.get("account_label") or label)
        if normalized == "omp":
            scope["consumers"].append({"id": identifier, "label": _text(label + " · " + account_label),
                                       "reading_ids": []})
        else:
            scope["accounts"].append({"id": identifier, "provider": normalized, "provider_label": label,
                                      "account_label": account_label, "canonical_ids": [], "reading_ids": []})
        # Account edits change the revision; launch layout and timestamps do not.
        definition = _definition(record, account_label)
        definitions.append(definition)
        if normalized != "omp":
            # An SSH record's user is a login on another machine, never a local account.
            remote = record.get("backend") == "ssh-command"
            local.append({"scope_id": scope_id, "id": identifier, "provider": normalized,
                          "label": account_label, "definition": definition,
                          "source_uid": None if remote else _local_uid(record, current_identity),
                          "revision": _digest(definition)})
    scope["revision"] = _digest(sorted(definitions, key=lambda item: item["id"]))
    scope["accounts"].sort(key=lambda item: item["id"])
    scope["consumers"].sort(key=lambda item: item["id"])
    return {"version": 1, "scopes": [scope]}, local
