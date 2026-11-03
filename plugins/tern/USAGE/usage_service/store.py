"""Private transactional state for USAGE; no provider data acquisition or reduction.

All public writes are atomic, including nested calls inside ``transaction()``.
Aggregate pages are immutable, authorization-bound, and bounded by the wire cap.
Large aggregate records travel as base64 record_chunks; inventory travels separately.
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
import hashlib
import ipaddress
import math
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from typing import Any, Iterator
from uuid import uuid4

from .protocol import (Authority, CLIENT_LEASE_SECONDS, MAX_BODY, PROTOCOL,
                       ServiceError, decode, digest, encode, identifier,
                       integer, text, validate_publication, validate_snapshot)

def _retain_muse_observations(reading: dict[str, Any], previous: dict[str, Any] | None) -> dict[str, Any]:
    """Keep exact measured windows for this source reading, never merge accounts."""
    if reading["provider"] != "muse" or reading.get("agent_id") == "omp" or reading.get("usage_source") == "headless" or not previous:
        return reading
    identity = reading.get("canonical_id") or reading.get("account_id")
    old_identity = previous.get("canonical_id") or previous.get("account_id")
    if previous["provider"] != "muse" or previous.get("agent_id") == "omp" or identity != old_identity:
        return reading
    measured = {}
    for candidate in (previous, reading):
        for window in candidate["windows"]:
            if window.get("used") is None or window.get("unavailable_reason") is not None:
                continue
            key = (window["key"], window["pool"])
            old = measured.get(key)
            if old is None or window["observed_at_ms"] >= old["observed_at_ms"]:
                measured[key] = window
    if not measured:
        return reading
    retained = dict(reading, windows=list(measured.values()))
    # Retention obeys the same bounded wire contract as every other observation.
    validate_snapshot({"version": 3, "publisher": "inventory", "as_of_ms": 0, "readings": [retained]})
    return retained


SCHEMA = 1
DEFAULTS = {
    "role": "standalone", "export_enabled": False, "metadata_enabled": False,
    "sharing_bind": None, "sharing_port": 0, "paused": False,
    "max_sources": 128, "max_publishers": 2048, "max_total_bytes": 32 * MAX_BODY,
    "max_inventory": 100_000, "max_page_bytes": MAX_BODY,
    "max_page_storage_bytes": 64 * MAX_BODY, "max_page_sessions": 32,
    "page_ttl_seconds": 120,
}
LIMITS = {
    "max_sources": (1, 4096), "max_publishers": (1, 65_536),
    "max_total_bytes": (1024, 1024 * MAX_BODY), "max_inventory": (1, 1_000_000),
    "max_page_bytes": (1024, MAX_BODY),
    "max_page_storage_bytes": (1024, 1024 * MAX_BODY),
    "max_page_sessions": (1, 1024), "page_ttl_seconds": (1, 300),
}
STALE_MS = 15 * 60 * 1000


def _opaque(value: Any, maximum: int = 256) -> str:
    value = text(value, maximum)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", value):
        raise ServiceError("invalid_request")
    return value


def _hash(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ServiceError("invalid_request")
    return value


def _handles(value: Any) -> list[str]:
    if not isinstance(value, list) or len(value) > 32:
        raise ServiceError("invalid_request")
    result = [_opaque(item) for item in value]
    if len(set(result)) != len(result):
        raise ServiceError("invalid_request")
    return sorted(result)


# Tables no longer written (collection_*, uploads, upload_chunks) stay in the DDL so
# stores created by earlier builds keep the same schema version.
_DDL = (
    "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS installations (id INTEGER PRIMARY KEY CHECK(id=1), device_id TEXT UNIQUE NOT NULL, generation TEXT NOT NULL, profile_generation INTEGER NOT NULL, group_id TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, auth_revision INTEGER NOT NULL DEFAULT 0)",
    "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS local_state (key TEXT PRIMARY KEY, value BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS publishers (publisher TEXT PRIMARY KEY, observer TEXT NOT NULL, group_id TEXT NOT NULL, epoch TEXT NOT NULL, sequence INTEGER NOT NULL, body_hash TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS publisher_epochs (publisher TEXT NOT NULL REFERENCES publishers(publisher) ON DELETE CASCADE, epoch TEXT NOT NULL, PRIMARY KEY(publisher,epoch))",
    "CREATE TABLE IF NOT EXISTS snapshots (publisher TEXT PRIMARY KEY REFERENCES publishers(publisher) ON DELETE CASCADE, source_id TEXT NOT NULL, received_ms INTEGER NOT NULL, payload BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS known_inventory (publisher TEXT NOT NULL REFERENCES publishers(publisher) ON DELETE CASCADE, reading_id TEXT NOT NULL, source_id TEXT NOT NULL, received_ms INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(publisher,reading_id))",
    "CREATE TABLE IF NOT EXISTS source_policies (source_id TEXT PRIMARY KEY, group_id TEXT NOT NULL, payload BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS pairings (device_id TEXT PRIMARY KEY, group_id TEXT NOT NULL, credential_hash TEXT UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, created_ms INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS invitations (token_hash TEXT PRIMARY KEY, group_id TEXT NOT NULL, expires_ms INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS local_clients (client_id TEXT PRIMARY KEY, kind TEXT NOT NULL, expires_ms INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS collection_leases (source_id TEXT PRIMARY KEY, observer TEXT NOT NULL, group_id TEXT NOT NULL, window_id TEXT NOT NULL, lease_id TEXT UNIQUE NOT NULL, request BLOB NOT NULL, expires_ms INTEGER NOT NULL, started_mono REAL NOT NULL, expires_mono REAL NOT NULL)",
    "CREATE TABLE IF NOT EXISTS collection_queue (position INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL, observer TEXT NOT NULL, group_id TEXT NOT NULL, window_id TEXT NOT NULL, request BLOB NOT NULL, expires_ms INTEGER NOT NULL, UNIQUE(source_id,observer,window_id))",
    "CREATE TABLE IF NOT EXISTS uploads (upload_id TEXT PRIMARY KEY, observer TEXT NOT NULL, group_id TEXT NOT NULL, auth_revision INTEGER NOT NULL, manifest BLOB NOT NULL, size INTEGER NOT NULL, expires_ms INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS upload_chunks (upload_id TEXT NOT NULL REFERENCES uploads(upload_id) ON DELETE CASCADE, chunk_index INTEGER NOT NULL, body_hash TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(upload_id,chunk_index))",
    "CREATE TABLE IF NOT EXISTS page_sessions (session_id TEXT PRIMARY KEY, observer TEXT NOT NULL, group_id TEXT NOT NULL, auth_revision INTEGER NOT NULL, expires_ms INTEGER NOT NULL, size INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS pages (cursor TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES page_sessions(session_id) ON DELETE CASCADE, payload BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS remote_hubs (hub_id TEXT PRIMARY KEY, revision TEXT NOT NULL, body_hash TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS remote_sources (hub_id TEXT NOT NULL REFERENCES remote_hubs(hub_id) ON DELETE CASCADE, source_id TEXT NOT NULL, group_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(hub_id,source_id))",
    "CREATE TABLE IF NOT EXISTS remote_records (hub_id TEXT NOT NULL REFERENCES remote_hubs(hub_id) ON DELETE CASCADE, publisher TEXT NOT NULL, observer TEXT NOT NULL, source_id TEXT NOT NULL, group_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(hub_id,publisher))",
    "CREATE TABLE IF NOT EXISTS remote_inventory (hub_id TEXT NOT NULL REFERENCES remote_hubs(hub_id) ON DELETE CASCADE, publisher TEXT NOT NULL, reading_id TEXT NOT NULL, observer TEXT NOT NULL, source_id TEXT NOT NULL, group_id TEXT NOT NULL, received_ms INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(hub_id,publisher,reading_id))",
)


class Store:
    def __init__(self, root: Path, clock=time.time):
        self.root = Path(root).absolute()
        self.path = self.root / "state.sqlite3"
        self.clock = clock
        self._lock = threading.RLock()
        self._depth = 0
        try:
            from .security import check_private, private_directory
            private_directory(self.root)
            try:
                fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                check_private(self.path)
            else:
                os.close(fd)
                check_private(self.path)
            self.connection = sqlite3.connect(self.path, timeout=30, isolation_level=None, check_same_thread=False)
            self.connection.row_factory = sqlite3.Row
            self.connection.execute("PRAGMA busy_timeout=30000")
            self.connection.execute("PRAGMA foreign_keys=ON")
            # Serialize cold-start schema and identity creation before switching WAL.
            with self.transaction() as db:
                for statement in _DDL:
                    db.execute(statement)
                version = db.execute("SELECT version FROM schema_version").fetchone()
                if version is None:
                    db.execute("INSERT INTO schema_version VALUES (?)", (SCHEMA,))
                elif version[0] != SCHEMA:
                    raise ServiceError("incompatible_version", 409)
                existing = db.execute("SELECT device_id FROM installations WHERE id=1").fetchone()
                if existing is None:
                    selected = str(uuid4())
                    generation, group = str(uuid4()), str(uuid4())
                    db.execute("INSERT INTO installations(id,device_id,generation,profile_generation,group_id) VALUES (1,?,?,0,?)", (selected, generation, group))
                    policy = {"source_id": selected, "generation": generation, "profile_generation": 0, "coordinator_id": selected, "observers": {}, "profiles": {}}
                    db.execute("INSERT INTO source_policies VALUES (?,?,?)", (selected, group, encode(policy)))
                for key, value in DEFAULTS.items():
                    db.execute("INSERT OR IGNORE INTO settings VALUES (?,?)", (key, encode(value)))
            # journal_mode's exclusive transition can return BUSY immediately
            # despite busy_timeout while another cold starter migrates.
            deadline = time.monotonic() + 30
            while True:
                try:
                    self.connection.execute("PRAGMA journal_mode=WAL")
                    break
                except sqlite3.OperationalError as exc:
                    if getattr(exc, "sqlite_errorcode", None) not in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED) or time.monotonic() >= deadline:
                        raise
                    time.sleep(0.01)
            self.connection.execute("PRAGMA synchronous=FULL")
            self._reissue_legacy_records()
        except (OSError, sqlite3.Error) as exc:
            if hasattr(self, "connection"):
                self.connection.close()
            raise ServiceError("companion_unavailable", 503) from exc
        except ServiceError:
            if hasattr(self, "connection"):
                self.connection.close()
            raise

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        """Serialize writers; nested operations use savepoints, never early commits."""
        with self._lock:
            nested = self._depth > 0
            savepoint = f"usage_{self._depth}"
            try:
                self.connection.execute(f"SAVEPOINT {savepoint}" if nested else "BEGIN IMMEDIATE")
                self._depth += 1
                try:
                    yield self.connection
                    self.connection.execute(f"RELEASE {savepoint}" if nested else "COMMIT")
                except BaseException:
                    if nested:
                        self.connection.execute(f"ROLLBACK TO {savepoint}")
                        self.connection.execute(f"RELEASE {savepoint}")
                    else:
                        self.connection.rollback()
                    raise
                finally:
                    self._depth -= 1
            except sqlite3.Error as exc:
                raise ServiceError("companion_unavailable", 503) from exc

    def close(self) -> None:
        with self._lock:
            self.connection.close()

    def _now(self) -> int:
        return int(self.clock() * 1000)

    def _identity(self, db: sqlite3.Connection) -> dict[str, Any]:
        row = dict(db.execute("SELECT * FROM installations WHERE id=1").fetchone())
        return {key: row[key] for key in ("device_id", "generation", "profile_generation", "group_id")} | {"protocol": PROTOCOL, "schema": SCHEMA}

    def identity(self) -> dict[str, Any]:
        with self.transaction() as db:
            return self._identity(db)

    def authorization_revision(self, authority: Authority) -> int:
        """Bind owner-local display cursors to the current authorization state."""
        with self.transaction() as db:
            self._authorize(db, authority)
            return db.execute("SELECT auth_revision FROM installations WHERE id=1").fetchone()[0]

    def _settings(self, db: sqlite3.Connection) -> dict[str, Any]:
        return {row[0]: decode(row[1]) for row in db.execute("SELECT key,value FROM settings")} | {"group_id": self._identity(db)["group_id"]}

    def settings(self) -> dict[str, Any]:
        with self.transaction() as db:
            return self._settings(db)

    def _bump(self, db: sqlite3.Connection, authorization: bool = False) -> None:
        db.execute("UPDATE installations SET revision=revision+1, auth_revision=auth_revision+? WHERE id=1", (int(authorization),))
        if authorization:
            db.execute("DELETE FROM page_sessions")

    def _authorize(self, db: sqlite3.Connection, authority: Authority) -> None:
        if not isinstance(authority, Authority):
            raise ServiceError("unauthorized", 401)
        identity = self._identity(db)
        if authority.local:
            if authority.device_id != identity["device_id"] or authority.group_id != identity["group_id"]:
                raise ServiceError("forbidden", 403)
            return
        row = db.execute("SELECT group_id,revoked FROM pairings WHERE device_id=?", (authority.device_id,)).fetchone()
        if row is None or row[1] or row[0] != authority.group_id:
            raise ServiceError("unauthorized", 401)

    def _cleanup(self, db: sqlite3.Connection) -> None:
        now = self._now()
        for table in ("page_sessions", "local_clients", "invitations"):
            db.execute(f"DELETE FROM {table} WHERE expires_ms<=?", (now,))

    def _capacity(self, db: sqlite3.Connection, settings: dict[str, Any] | None = None) -> None:
        limits = settings or self._settings(db)
        sources = db.execute("SELECT count(*) FROM (SELECT source_id FROM source_policies UNION SELECT source_id FROM snapshots UNION SELECT source_id FROM remote_sources UNION SELECT source_id FROM known_inventory)").fetchone()[0]
        publishers = db.execute("SELECT count(*) FROM (SELECT publisher FROM publishers UNION SELECT publisher FROM remote_records)").fetchone()[0]
        size = 0
        inventory = 0
        for table in ("snapshots", "known_inventory", "remote_records", "remote_inventory", "remote_sources", "source_policies"):
            row = db.execute(f"SELECT count(*),coalesce(sum(length(payload)),0) FROM {table}").fetchone()
            size += row[1]
            if table in ("known_inventory", "remote_inventory"):
                inventory += row[0]
        pages = db.execute("SELECT count(*),coalesce(sum(size),0) FROM page_sessions").fetchone()
        if (sources > limits["max_sources"] or publishers > limits["max_publishers"] or size > limits["max_total_bytes"]
                or inventory > limits["max_inventory"]
                or pages[0] > limits["max_page_sessions"] or pages[1] > limits["max_page_storage_bytes"]):
            raise ServiceError("capacity", 413)

    def configure(self, changes: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(changes, dict):
            raise ServiceError("invalid_request")
        cleaned = {}
        for key, value in changes.items():
            if key in LIMITS:
                value = integer(value, *LIMITS[key])
            elif key in ("export_enabled", "metadata_enabled", "paused"):
                if not isinstance(value, bool):
                    raise ServiceError("invalid_request")
            elif key == "role":
                if value not in ("standalone", "hub", "member"):
                    raise ServiceError("invalid_request")
            elif key == "sharing_bind":
                if value is not None:
                    try:
                        value = str(ipaddress.ip_address(value))
                    except (ValueError, TypeError) as exc:
                        raise ServiceError("invalid_request") from exc
            elif key == "sharing_port":
                value = integer(value, 0, 65535)
            elif key == "group_id":
                value = _opaque(value, 128)
            else:
                raise ServiceError("invalid_request")
            cleaned[key] = value
        with self.transaction() as db:
            self._cleanup(db)
            old = self._settings(db)
            updated = old | cleaned
            self._capacity(db, updated)
            for key, value in cleaned.items():
                if key != "group_id":
                    db.execute("INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, encode(value)))
            if updated["group_id"] != old["group_id"]:
                if db.execute("SELECT 1 FROM pairings WHERE revoked=0 LIMIT 1").fetchone():
                    raise ServiceError("conflict", 409)
                own = self._identity(db)["device_id"]
                db.execute("UPDATE installations SET group_id=? WHERE id=1", (updated["group_id"],))
                db.execute("UPDATE publishers SET group_id=? WHERE observer=?", (updated["group_id"], own))
                db.execute("UPDATE source_policies SET group_id=? WHERE source_id=?", (updated["group_id"], own))
                db.execute("DELETE FROM remote_hubs")
                db.execute("DELETE FROM invitations")
                self._bump(db, True)
            elif cleaned:
                self._bump(db, old["export_enabled"] and not updated["export_enabled"])
            return updated

    def local_state(self, key: str) -> Any:
        key = _opaque(key, 128)
        with self.transaction() as db:
            row = db.execute("SELECT value FROM local_state WHERE key=?", (key,)).fetchone()
            return decode(row[0]) if row else None

    def set_local_state(self, key: str, value: Any) -> None:
        key, raw = _opaque(key, 128), encode(value)
        if len(raw) > MAX_BODY:
            raise ServiceError("capacity", 413)
        with self.transaction() as db:
            db.execute("INSERT INTO local_state VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, raw))
            row = db.execute("SELECT count(*),sum(length(value)) FROM local_state").fetchone()
            if row[0] > 128 or row[1] > 16 * MAX_BODY:
                raise ServiceError("capacity", 413)

    def _policy(self, db: sqlite3.Connection, source_id: str) -> dict[str, Any] | None:
        row = db.execute("SELECT payload FROM source_policies WHERE source_id=?", (source_id,)).fetchone()
        return decode(row[0]) if row else None

    def source_policy(self, source_id: str | None = None) -> dict[str, Any] | None:
        with self.transaction() as db:
            return self._policy(db, identifier(source_id) if source_id is not None else self._identity(db)["device_id"])

    def set_source_policy(self, authority: Authority, policy: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(policy, dict) or set(policy) != {"source_id", "generation", "profile_generation", "coordinator_id", "observers", "profiles"}:
            raise ServiceError("invalid_request")
        result = {key: identifier(policy.get(key)) for key in ("source_id", "generation", "coordinator_id")}
        result["profile_generation"] = integer(policy.get("profile_generation"))
        observers, profiles = policy.get("observers"), policy.get("profiles")
        if not isinstance(observers, dict) or not isinstance(profiles, dict) or len(observers) > 4096 or len(profiles) > 1024:
            raise ServiceError("invalid_request")
        result["profiles"] = {}
        for handle, profile in profiles.items():
            handle = _opaque(handle)
            if not isinstance(profile, dict) or set(profile) != {"generation", "canonical_ids"}:
                raise ServiceError("invalid_request")
            ids = profile["canonical_ids"]
            if not isinstance(ids, list) or not 1 <= len(ids) <= 1000:
                raise ServiceError("invalid_request")
            result["profiles"][handle] = {"generation": integer(profile["generation"]), "canonical_ids": sorted(set(text(item, 4096) for item in ids))}
        result["observers"] = {identifier(observer): _handles(handles) for observer, handles in observers.items()}
        for handles in result["observers"].values():
            if not handles or not set(handles) <= result["profiles"].keys():
                raise ServiceError("invalid_request")
        raw = encode(result)
        if len(raw) > MAX_BODY:
            raise ServiceError("capacity", 413)
        with self.transaction() as db:
            self._authorize(db, authority)
            if result["source_id"] != authority.device_id:
                raise ServiceError("forbidden", 403)
            old = self._policy(db, authority.device_id)
            if old == result:
                return result
            if old and old["generation"] == result["generation"]:
                if result["profile_generation"] < old["profile_generation"]:
                    raise ServiceError("replay", 409)
                changed_profiles = old["profiles"] != result["profiles"]
                if changed_profiles and result["profile_generation"] <= old["profile_generation"]:
                    raise ServiceError("conflict", 409)
                for handle, profile in result["profiles"].items():
                    previous = old["profiles"].get(handle)
                    if previous and previous != profile and profile["generation"] <= previous["generation"]:
                        raise ServiceError("conflict", 409)
            db.execute("INSERT INTO source_policies VALUES (?,?,?) ON CONFLICT(source_id) DO UPDATE SET group_id=excluded.group_id,payload=excluded.payload", (authority.device_id, authority.group_id, raw))
            # Old observer associations do not authorize their cached advertised data.
            db.execute("DELETE FROM known_inventory WHERE source_id=? AND publisher IN (SELECT publisher FROM publishers WHERE observer<>?)", (authority.device_id, authority.device_id))
            db.execute("DELETE FROM snapshots WHERE source_id=? AND publisher IN (SELECT publisher FROM publishers WHERE observer<>?)", (authority.device_id, authority.device_id))
            if authority.local:
                db.execute("UPDATE installations SET generation=?,profile_generation=? WHERE id=1", (result["generation"], result["profile_generation"]))
            self._capacity(db)
            self._bump(db, True)
            return result

    def _association(self, db: sqlite3.Connection, authority: Authority, request: dict[str, Any], readings: list[dict[str, Any]] | None = None) -> dict[str, Any] | None:
        source = request["subject_source_id"]
        policy = self._policy(db, source)
        handles = _handles(request.get("profile_handles", []))
        if policy:
            row = db.execute("SELECT group_id FROM source_policies WHERE source_id=?", (source,)).fetchone()
            if row[0] != authority.group_id or policy["generation"] != request["generation"] or policy["profile_generation"] != request["profile_generation"]:
                raise ServiceError("forbidden", 403)
        if source != authority.device_id:
            permitted = policy["observers"].get(authority.device_id, []) if policy else []
            if not handles or not set(handles) <= set(permitted):
                raise ServiceError("forbidden", 403)
            canonical_ids = {canonical for handle in handles for canonical in policy["profiles"][handle]["canonical_ids"]}
            if readings is not None and any(reading.get("canonical_id") not in canonical_ids for reading in readings):
                raise ServiceError("forbidden", 403)
        elif handles and (not policy or not set(handles) <= policy["profiles"].keys()):
            raise ServiceError("forbidden", 403)
        return policy

    def _publish(self, db: sqlite3.Connection, authority: Authority, publication: dict[str, Any]) -> dict[str, Any]:
        self._authorize(db, authority)
        if publication["observer_device_id"] != authority.device_id or not publication["publisher"].startswith(authority.device_id + ":"):
            raise ServiceError("forbidden", 403)
        _opaque(publication["publisher"][37:], 475)
        self._association(db, authority, publication, publication["snapshot"]["readings"])
        publisher, epoch, sequence = publication["publisher"], publication["epoch"], publication["sequence"]
        body = encode(publication)
        body_hash = hashlib.sha256(body).hexdigest()
        old = db.execute("SELECT * FROM publishers WHERE publisher=?", (publisher,)).fetchone()
        idempotent = False
        if old:
            if old["observer"] != authority.device_id or old["group_id"] != authority.group_id:
                raise ServiceError("forbidden", 403)
            if old["epoch"] == epoch:
                if sequence < old["sequence"]:
                    raise ServiceError("replay", 409)
                if sequence == old["sequence"]:
                    if old["body_hash"] != body_hash:
                        raise ServiceError("conflict", 409)
                    idempotent = True
            elif db.execute("SELECT 1 FROM publisher_epochs WHERE publisher=? AND epoch=?", (publisher, epoch)).fetchone():
                raise ServiceError("replay", 409)
        if idempotent:
            return {"ok": True, "idempotent": True, "publication": publication}
        now = self._now()
        db.execute("INSERT INTO publishers VALUES (?,?,?,?,?,?) ON CONFLICT(publisher) DO UPDATE SET epoch=excluded.epoch,sequence=excluded.sequence,body_hash=excluded.body_hash", (publisher, authority.device_id, authority.group_id, epoch, sequence, body_hash))
        db.execute("INSERT OR IGNORE INTO publisher_epochs VALUES (?,?)", (publisher, epoch))
        if db.execute("SELECT count(*) FROM publisher_epochs WHERE publisher=?", (publisher,)).fetchone()[0] > 4096:
            raise ServiceError("capacity", 413)
        db.execute("INSERT INTO snapshots VALUES (?,?,?,?) ON CONFLICT(publisher) DO UPDATE SET source_id=excluded.source_id,received_ms=excluded.received_ms,payload=excluded.payload", (publisher, publication["subject_source_id"], now, body))
        for reading in publication["snapshot"]["readings"]:
            previous = db.execute("SELECT payload FROM known_inventory WHERE publisher=? AND reading_id=?", (publisher, reading["id"])).fetchone() if reading["provider"] == "muse" else None
            reading = _retain_muse_observations(reading, decode(previous[0]) if previous else None)
            db.execute("INSERT INTO known_inventory VALUES (?,?,?,?,?) ON CONFLICT(publisher,reading_id) DO UPDATE SET source_id=excluded.source_id,received_ms=excluded.received_ms,payload=excluded.payload", (publisher, reading["id"], publication["subject_source_id"], now, encode(reading)))
        self._capacity(db)
        self._bump(db)
        return {"ok": True, "idempotent": False, "publication": publication}

    def publish(self, authority: Authority, publication: dict[str, Any]) -> dict[str, Any]:
        publication = validate_publication(publication)
        with self.transaction() as db:
            return self._publish(db, authority, publication)

    def local_publish(self, observer_key: str, snapshot: dict[str, Any], *, replace_inventory: bool = False) -> dict[str, Any]:
        observer_key = _opaque(observer_key, 475)
        if not isinstance(snapshot, dict):
            raise ServiceError("snapshot_rejected")
        with self.transaction() as db:
            identity = self._identity(db)
            publisher = identity["device_id"] + ":" + observer_key
            previous = db.execute("SELECT epoch,sequence FROM publishers WHERE publisher=?", (publisher,)).fetchone()
            policy = self._policy(db, identity["device_id"])
            publication = validate_publication({
                "protocol": PROTOCOL, "observer_device_id": identity["device_id"], "subject_source_id": identity["device_id"],
                "publisher": publisher, "epoch": previous[0] if previous else str(uuid4()),
                "sequence": previous[1] + 1 if previous else 1, "kind": "passive",
                "generation": policy["generation"] if policy else identity["generation"],
                "profile_generation": policy["profile_generation"] if policy else identity["profile_generation"],
                "snapshot": snapshot | {"publisher": publisher},
            })
            if replace_inventory:
                # A complete source-owned projection includes its own same-identity
                # last-known windows. Removed/redefined accounts must not reappear.
                db.execute("DELETE FROM known_inventory WHERE publisher=?", (publisher,))
            self._publish(db, Authority(identity["device_id"], identity["group_id"], "owner", True), publication)
            return publication

    def local_records(self) -> list[dict[str, Any]]:
        with self.transaction() as db:
            own = self._identity(db)["device_id"]
            return [decode(row[0]) for row in db.execute("SELECT s.payload FROM snapshots s JOIN publishers p USING(publisher) WHERE p.observer=? ORDER BY s.publisher", (own,))]

    def _reissue_legacy_records(self) -> None:
        """Republish own records written by pre-2.0 builds under the next sequence.

        validate_publication normalizes legacy values (e.g. usage_source), so a
        resend of the stored sequence would hash differently from what a hub
        already accepted and fail with a permanent ``conflict``.
        """
        with self.transaction() as db:
            own = self._identity(db)["device_id"]
            rows = db.execute("SELECT s.publisher,s.payload FROM snapshots s JOIN publishers p USING(publisher) WHERE p.observer=?", (own,)).fetchall()
            for publisher, payload in rows:
                raw = decode(payload)
                if not isinstance(raw, dict) or raw.get("kind") == "active" or not publisher.startswith(own + ":"):
                    continue
                try:
                    if encode(validate_publication(raw)) != bytes(payload):
                        self.local_publish(publisher[len(own) + 1:], raw["snapshot"])
                except ServiceError:
                    # An unreadable or over-capacity row stays as stored; it never blocks opening.
                    continue

    def _view(self, db: sqlite3.Connection, group_id: str) -> tuple[list, list, list]:
        # Delegated "active" records from pre-2.0 builds are no longer valid publications.
        records = {row[0]: value for row in db.execute("SELECT publisher,payload FROM remote_records WHERE group_id=? ORDER BY hub_id,publisher", (group_id,))
                   if (value := decode(row[1])).get("kind") != "active"}
        records.update({row[0]: value for row in db.execute("SELECT s.publisher,s.payload FROM snapshots s JOIN publishers p USING(publisher) WHERE p.group_id=? ORDER BY s.publisher", (group_id,))
                        if (value := decode(row[1])).get("kind") != "active"})
        sources = {row[0]: decode(row[1]) for row in db.execute("SELECT source_id,payload FROM remote_sources WHERE group_id=? ORDER BY hub_id,source_id", (group_id,))}
        inventory = {}
        for row in db.execute("SELECT publisher,observer,source_id,received_ms,payload FROM remote_inventory WHERE group_id=? ORDER BY hub_id,publisher,reading_id", (group_id,)):
            reading = decode(row[4])
            inventory[(row[0], reading["id"])] = {"publisher": row[0], "observer_device_id": row[1], "subject_source_id": row[2], "last_received_ms": row[3], "reading": reading}
        for row in db.execute("SELECT i.publisher,p.observer,i.source_id,i.received_ms,i.payload FROM known_inventory i JOIN publishers p USING(publisher) WHERE p.group_id=? ORDER BY i.publisher,i.reading_id", (group_id,)):
            reading = decode(row[4])
            inventory[(row[0], reading["id"])] = {"publisher": row[0], "observer_device_id": row[1], "subject_source_id": row[2], "last_received_ms": row[3], "reading": reading}
        for row in db.execute("SELECT payload FROM source_policies WHERE group_id=?", (group_id,)):
            policy = decode(row[0])
            sources[policy["source_id"]] = {"source_id": policy["source_id"], "generation": policy["generation"], "profile_generation": policy["profile_generation"], "last_received_ms": None, "status": "not_yet_measured", "clock_skew": False}
        for row in db.execute("SELECT s.source_id,s.received_ms,s.payload FROM snapshots s JOIN publishers p USING(publisher) WHERE p.group_id=? ORDER BY s.received_ms", (group_id,)):
            publication = decode(row[2])
            measured = publication["snapshot"]["as_of_ms"]
            previous = sources.get(row[0], {})
            sources[row[0]] = {"source_id": row[0], "generation": previous.get("generation", publication["generation"]), "profile_generation": previous.get("profile_generation", publication["profile_generation"]), "last_received_ms": row[1], "status": "stale" if self._now() - measured > STALE_MS else "current", "clock_skew": measured > self._now() + 300_000}
        for entry in inventory.values():
            if entry["subject_source_id"] not in sources:
                sources[entry["subject_source_id"]] = {"source_id": entry["subject_source_id"], "last_received_ms": entry["last_received_ms"], "status": "stale", "clock_skew": False}
        # Received timestamps never extend an observation's freshness.
        for source in sources.values():
            observed = [record["snapshot"]["as_of_ms"] for record in records.values() if record["subject_source_id"] == source["source_id"]]
            if source["status"] not in ("offline", "source_unreachable"):
                source["status"] = ("stale" if self._now() - max(observed) > STALE_MS else "current") if observed else source["status"]
        return [records[key] for key in sorted(records)], [sources[key] for key in sorted(sources)], [inventory[key] for key in sorted(inventory)]

    def _cached_snapshots(self, db: sqlite3.Connection) -> list[dict[str, Any]]:
        """Read display caches imported by pre-2.0 builds; nothing writes them now.

        validate_snapshot normalizes their legacy usage_source values and assigns no authority.
        """
        row = db.execute("SELECT value FROM local_state WHERE key='cached_snapshot_index'").fetchone()
        index = decode(row[0]) if row else []
        if not isinstance(index, list) or len(index) > 128:
            raise ServiceError("invalid_request")
        snapshots = {}
        for key in dict.fromkeys(_opaque(item, 128) for item in index):
            if not key.startswith("cached_snapshot:"):
                raise ServiceError("invalid_request")
            _hash(key.removeprefix("cached_snapshot:"))
            row = db.execute("SELECT value FROM local_state WHERE key=?", (key,)).fetchone()
            if row is None:
                raise ServiceError("invalid_request")
            snapshot = validate_snapshot(decode(row[0]))
            snapshots[digest(snapshot)] = snapshot
        history = db.execute("SELECT value FROM local_state WHERE key='muse_history'").fetchone()
        if history is not None and decode(history[0]) is not None:
            snapshot = validate_snapshot(decode(history[0]))
            snapshots[digest(snapshot)] = snapshot
        return list(snapshots.values())

    def aggregate(self, authority: Authority, cursor: str | None = None, page_bytes: int = 262144) -> dict[str, Any]:
        page_bytes = integer(page_bytes, 1024, MAX_BODY)
        with self.transaction() as db:
            self._authorize(db, authority)
            self._cleanup(db)
            auth_revision = db.execute("SELECT auth_revision FROM installations WHERE id=1").fetchone()[0]
            if cursor is not None:
                cursor = _opaque(cursor)
                row = db.execute("SELECT p.payload,s.observer,s.group_id,s.auth_revision FROM pages p JOIN page_sessions s USING(session_id) WHERE p.cursor=?", (cursor,)).fetchone()
                if row is None:
                    raise ServiceError("expired", 410)
                if row[1] != authority.device_id or row[2] != authority.group_id or row[3] != auth_revision:
                    raise ServiceError("forbidden", 403)
                return decode(row[0])
            limits = self._settings(db)
            self._capacity(db, limits)
            target = min(page_bytes, limits["max_page_bytes"])
            records, sources, inventory = self._view(db, authority.group_id)
            if not authority.local and not limits["export_enabled"]:
                own = self._identity(db)["device_id"]
                records = [record for record in records if record["observer_device_id"] != own]
                inventory = [entry for entry in inventory if entry["observer_device_id"] != own]
            revision = secrets.token_hex(16)
            base = {"revision": revision, "records": [], "sources": [], "inventory": [], "record_chunks": [], "next_cursor": None, "complete": False, "incomplete": False}
            cached = self._cached_snapshots(db) if authority.local else []
            if authority.local:
                base.update(cached_snapshots=[], cached_chunks=[])
            page_fields = tuple(key for key, value in base.items() if isinstance(value, list))
            units = []
            # Reserve response framing and a full opaque continuation token.
            budget = target - len(encode(base)) - 128
            for field, chunk_field, values in (("records", "record_chunks", records), ("cached_snapshots", "cached_chunks", cached)):
                for record in values:
                    raw = encode(record)
                    if len(raw) <= budget:
                        units.append((field, record))
                    else:
                        chunk_size = min(48 * 1024, max(1, (budget - 192) * 3 // 4))
                        count = math.ceil(len(raw) / chunk_size)
                        record_id = hashlib.sha256(raw).hexdigest()
                        for index in range(count):
                            units.append((chunk_field, {"record_id": record_id, "index": index, "count": count, "size": len(raw), "data": base64.b64encode(raw[index * chunk_size:(index + 1) * chunk_size]).decode("ascii")}))
            units.extend(("sources", source) for source in sources)
            units.extend(("inventory", entry) for entry in inventory)
            page_list, page = [], {key: ([] if isinstance(value, list) else value) for key, value in base.items()}
            size = len(encode(page)) + 128
            for key, value in units:
                item_size = len(encode(value)) + 1
                if size + item_size > target and any(page[field] for field in page_fields):
                    page_list.append(page)
                    page = {key: ([] if isinstance(value, list) else value) for key, value in base.items()}
                    size = len(encode(page)) + 128
                # A single inventory reading is bounded by snapshot MAX_BODY,
                # but may exceed the target. The hard wire bound still applies.
                if size + item_size > limits["max_page_bytes"]:
                    raise ServiceError("capacity", 413)
                page[key].append(value)
                size += item_size
            page_list.append(page)
            tokens = [secrets.token_urlsafe(32) for _ in page_list]
            payloads = []
            for index, page in enumerate(page_list):
                page["next_cursor"] = tokens[index + 1] if index + 1 < len(tokens) else None
                page["complete"] = index + 1 == len(tokens)
                payloads.append(encode(page))
            total = sum(map(len, payloads))
            if len(payloads) > 1:
                session = secrets.token_urlsafe(32)
                db.execute("INSERT INTO page_sessions VALUES (?,?,?,?,?,?)", (session, authority.device_id, authority.group_id, auth_revision, self._now() + limits["page_ttl_seconds"] * 1000, total))
                db.executemany("INSERT INTO pages VALUES (?,?,?)", [(token, session, payload) for token, payload in zip(tokens, payloads)])
                self._capacity(db, limits)
            return page_list[0]

    def register_client(self, client_id: str, kind: str, ttl_seconds: int = CLIENT_LEASE_SECONDS) -> dict[str, Any]:
        client_id, ttl_seconds = _opaque(client_id), integer(ttl_seconds, 1, CLIENT_LEASE_SECONDS)
        if kind not in ("host", "window"):
            raise ServiceError("invalid_request")
        with self.transaction() as db:
            self._cleanup(db)
            expires = self._now() + ttl_seconds * 1000
            db.execute("INSERT INTO local_clients VALUES (?,?,?) ON CONFLICT(client_id) DO UPDATE SET kind=excluded.kind,expires_ms=excluded.expires_ms", (client_id, kind, expires))
            if db.execute("SELECT count(*) FROM local_clients").fetchone()[0] > 4096:
                raise ServiceError("capacity", 413)
            return {"client_id": client_id, "expires_at_ms": expires, "duration_ms": ttl_seconds * 1000}

    def expire_clients(self) -> int:
        with self.transaction() as db:
            return db.execute("DELETE FROM local_clients WHERE expires_ms<=?", (self._now(),)).rowcount

    def has_live_clients(self) -> bool:
        with self.transaction() as db:
            return db.execute("SELECT 1 FROM local_clients WHERE expires_ms>? LIMIT 1", (self._now(),)).fetchone() is not None

    def create_invitation(self, token_hash: str, expires_ms: int, group_id: str) -> None:
        token_hash, group_id, expires_ms = _hash(token_hash), _opaque(group_id, 128), integer(expires_ms)
        with self.transaction() as db:
            self._cleanup(db)
            if not self._now() < expires_ms <= self._now() + 600_000 or group_id != self._identity(db)["group_id"]:
                raise ServiceError("invalid_request")
            if db.execute("SELECT count(*) FROM invitations").fetchone()[0] >= 128:
                raise ServiceError("capacity", 413)
            if db.execute("SELECT 1 FROM invitations WHERE token_hash=?", (token_hash,)).fetchone():
                raise ServiceError("conflict", 409)
            db.execute("INSERT INTO invitations VALUES (?,?,?)", (token_hash, group_id, expires_ms))

    def consume_invitation(self, token_hash: str, now_ms: int, device_id: str, credential_hash: str) -> dict[str, Any]:
        token_hash, device_id, credential_hash, now_ms = _hash(token_hash), identifier(device_id), _hash(credential_hash), integer(now_ms)
        with self.transaction() as db:
            invitation = db.execute("SELECT * FROM invitations WHERE token_hash=?", (token_hash,)).fetchone()
            if not invitation or invitation["expires_ms"] <= max(now_ms, self._now()):
                raise ServiceError("expired", 410)
            if device_id == self._identity(db)["device_id"]:
                raise ServiceError("forbidden", 403)
            if db.execute("SELECT 1 FROM pairings WHERE credential_hash=? OR (device_id=? AND revoked=0)", (credential_hash, device_id)).fetchone():
                raise ServiceError("conflict", 409)
            if db.execute("SELECT count(*) FROM pairings WHERE revoked=0").fetchone()[0] >= self._settings(db)["max_sources"]:
                raise ServiceError("capacity", 413)
            db.execute("DELETE FROM invitations WHERE token_hash=?", (token_hash,))
            db.execute("INSERT INTO pairings VALUES (?,?,?,0,?) ON CONFLICT(device_id) DO UPDATE SET group_id=excluded.group_id,credential_hash=excluded.credential_hash,revoked=0,created_ms=excluded.created_ms", (device_id, invitation["group_id"], credential_hash, self._now()))
            self._bump(db, True)
            return {"group_id": invitation["group_id"]}

    def peers(self) -> list[dict[str, Any]]:
        """Internal credential-verifier access for Security; never a diagnostic payload."""
        with self.transaction() as db:
            return [dict(row) for row in db.execute("SELECT * FROM pairings ORDER BY device_id")]

    def revoke_peer(self, device_id: str) -> dict[str, Any]:
        device_id = identifier(device_id)
        with self.transaction() as db:
            if device_id == self._identity(db)["device_id"]:
                raise ServiceError("forbidden", 403)
            db.execute("UPDATE pairings SET revoked=1 WHERE device_id=?", (device_id,))
            # Keep the replay ledger through revoke/re-pair; only advertised data
            # and credentials lose authority.
            for table in ("snapshots", "known_inventory"):
                db.execute(f"DELETE FROM {table} WHERE source_id=? OR publisher IN (SELECT publisher FROM publishers WHERE observer=?)", (device_id, device_id))
            db.execute("DELETE FROM source_policies WHERE source_id=?", (device_id,))
            for row in db.execute("SELECT source_id,payload FROM source_policies").fetchall():
                policy = decode(row[1])
                if device_id in policy["observers"]:
                    del policy["observers"][device_id]
                    db.execute("UPDATE source_policies SET payload=? WHERE source_id=?", (encode(policy), row[0]))
            db.execute("DELETE FROM remote_hubs WHERE hub_id=?", (device_id,))
            for table in ("remote_records", "remote_inventory"):
                db.execute(f"DELETE FROM {table} WHERE observer=? OR source_id=?", (device_id, device_id))
            db.execute("DELETE FROM remote_sources WHERE source_id=?", (device_id,))
            self._bump(db, True)
            return {"ok": True}

    def replace_remote(self, hub_device_id: str, revision: str, records: list, sources: list) -> dict[str, Any]:
        hub_device_id, revision = identifier(hub_device_id), _opaque(revision)
        if not isinstance(records, list) or not isinstance(sources, list):
            raise ServiceError("invalid_request")
        publications = [validate_publication(record) for record in records]
        if len({record["publisher"] for record in publications}) != len(publications):
            raise ServiceError("conflict", 409)
        normalized_sources, inventory = {}, []
        for source in sources:
            if not isinstance(source, dict):
                raise ServiceError("invalid_request")
            source_id = identifier(source.get("source_id"))
            if source_id in normalized_sources or source.get("status") not in ("current", "stale", "offline", "not_yet_measured", "source_unreachable"):
                raise ServiceError("invalid_request")
            normalized = {"source_id": source_id, "status": source["status"], "last_received_ms": None if source.get("last_received_ms") is None else integer(source["last_received_ms"]), "clock_skew": source.get("clock_skew") is True}
            if "generation" in source:
                normalized["generation"] = identifier(source["generation"])
            if "profile_generation" in source:
                normalized["profile_generation"] = integer(source["profile_generation"])
            entries = source.get("inventory", [])
            if not isinstance(entries, list):
                raise ServiceError("invalid_request")
            for entry in entries:
                if not isinstance(entry, dict):
                    raise ServiceError("invalid_request")
                observer, publisher = identifier(entry.get("observer_device_id")), text(entry.get("publisher"), 512)
                if not publisher.startswith(observer + ":"):
                    raise ServiceError("forbidden", 403)
                reading = validate_snapshot({"version": 3, "publisher": publisher, "as_of_ms": 0, "readings": [entry.get("reading")]})["readings"][0]
                inventory.append((publisher, observer, source_id, integer(entry.get("last_received_ms")), reading))
            normalized_sources[source_id] = normalized
        if any(record["subject_source_id"] not in normalized_sources for record in publications):
            raise ServiceError("invalid_request")
        body_hash = digest({"records": publications, "sources": sources})
        with self.transaction() as db:
            identity = self._identity(db)
            if hub_device_id == identity["device_id"]:
                raise ServiceError("forbidden", 403)
            old = db.execute("SELECT revision,body_hash FROM remote_hubs WHERE hub_id=?", (hub_device_id,)).fetchone()
            if old and old[0] == revision:
                if old[1] != body_hash:
                    raise ServiceError("conflict", 409)
                return {"ok": True, "idempotent": True}
            db.execute("INSERT INTO remote_hubs VALUES (?,?,?) ON CONFLICT(hub_id) DO UPDATE SET revision=excluded.revision,body_hash=excluded.body_hash", (hub_device_id, revision, body_hash))
            old_source_state = {row[0]: decode(row[1]) for row in db.execute("SELECT source_id,payload FROM remote_sources WHERE hub_id=?", (hub_device_id,))}
            old_sources = set(old_source_state)
            old_observers = {row[0] for row in db.execute("SELECT observer FROM remote_records WHERE hub_id=?", (hub_device_id,))}
            removed_authority = bool(old_sources - normalized_sources.keys() or old_observers - {record["observer_device_id"] for record in publications})
            removed_authority = removed_authority or any(
                any(previous.get(key) != normalized_sources[source_id].get(key) for key in ("generation", "profile_generation"))
                for source_id, previous in old_source_state.items() if source_id in normalized_sources)
            # This is a complete authenticated projection, not a partial fetch.
            # Failed/disconnected fetches must never call this method.
            for table in ("remote_sources", "remote_records", "remote_inventory"):
                db.execute(f"DELETE FROM {table} WHERE hub_id=?", (hub_device_id,))
            for source_id, source in normalized_sources.items():
                if source_id != identity["device_id"]:
                    db.execute("INSERT INTO remote_sources VALUES (?,?,?,?) ON CONFLICT(hub_id,source_id) DO UPDATE SET group_id=excluded.group_id,payload=excluded.payload", (hub_device_id, source_id, identity["group_id"], encode(source)))
            for record in publications:
                # This installation's own records come from its local snapshots.
                if record["observer_device_id"] == identity["device_id"]:
                    continue
                if not record["publisher"].startswith(record["observer_device_id"] + ":"):
                    raise ServiceError("forbidden", 403)
                db.execute("INSERT INTO remote_records VALUES (?,?,?,?,?,?) ON CONFLICT(hub_id,publisher) DO UPDATE SET observer=excluded.observer,source_id=excluded.source_id,group_id=excluded.group_id,payload=excluded.payload", (hub_device_id, record["publisher"], record["observer_device_id"], record["subject_source_id"], identity["group_id"], encode(record)))
                source = normalized_sources[record["subject_source_id"]]
                for reading in record["snapshot"]["readings"]:
                    inventory.append((record["publisher"], record["observer_device_id"], record["subject_source_id"], source["last_received_ms"] or 0, reading))
            for publisher, observer, source_id, received_ms, reading in inventory:
                if observer == identity["device_id"]:
                    continue
                previous = db.execute("SELECT payload FROM remote_inventory WHERE hub_id=? AND publisher=? AND reading_id=?", (hub_device_id, publisher, reading["id"])).fetchone() if reading["provider"] == "muse" else None
                reading = _retain_muse_observations(reading, decode(previous[0]) if previous else None)
                db.execute("INSERT INTO remote_inventory VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(hub_id,publisher,reading_id) DO UPDATE SET observer=excluded.observer,source_id=excluded.source_id,group_id=excluded.group_id,received_ms=excluded.received_ms,payload=excluded.payload", (hub_device_id, publisher, reading["id"], observer, source_id, identity["group_id"], received_ms, encode(reading)))
            self._capacity(db)
            self._bump(db, removed_authority)
            return {"ok": True, "idempotent": False}

    def diagnostics(self) -> dict[str, Any]:
        with self.transaction() as db:
            self._cleanup(db)
            counts = {}
            for name, query in {
                "publishers": "SELECT count(*) FROM publishers", "snapshots": "SELECT count(*) FROM snapshots",
                "known_inventory": "SELECT count(*) FROM known_inventory", "remote_snapshots": "SELECT count(*) FROM remote_records",
                "remote_inventory": "SELECT count(*) FROM remote_inventory", "peers": "SELECT count(*) FROM pairings WHERE revoked=0",
                "local_clients": "SELECT count(*) FROM local_clients", "page_sessions": "SELECT count(*) FROM page_sessions",
            }.items():
                counts[name] = db.execute(query).fetchone()[0]
            return {"protocol": PROTOCOL, "schema": SCHEMA, "role": self._settings(db)["role"], "counts": counts}
