"""Read-only consumer evidence. No provider collection or account reduction.

All private authority stays inside USAGE. Sessions authorize same-user native
readers, not authenticated plugin identities. Validation is a point-in-time check.
"""
from __future__ import annotations

import hashlib
import re
import secrets
import time

from .protocol import ServiceError, encode
from .store import STALE_MS
from .sync import _Assembly

PART_BYTES = 32768
MAX_BYTES = 8 * 1024 * 1024
MAX_PAGES = 256


def _opaque(value, maximum=128):
    return isinstance(value, str) and bool(re.fullmatch(r"[A-Za-z0-9_.:-]{1," + str(maximum) + r"}", value))


class Capacity:
    def __init__(self, store, configuration=None, clock=time.monotonic):
        self.store, self.configuration, self.clock = store, configuration, clock
        self.sessions = {}
        self.revoked = {}

    def _document(self, authority, authorization):
        limits = dict(self.store.settings())
        limits["max_total_bytes"] = min(limits["max_total_bytes"], MAX_BYTES)
        assembly = _Assembly(limits)
        cursor = None
        first_cursor = None
        # Existing assembler owns completeness, publication normalization and bounds.
        # Its temporary pages must not consume Display/peer session capacity.
        try:
            while True:
                page = self.store.aggregate(authority, cursor)
                if first_cursor is None:
                    first_cursor = page.get("next_cursor")
                cursor = assembly.add(page, local_cache=True)
                if cursor is None:
                    break
            _, records, sources = assembly.finish()
        finally:
            if first_cursor is not None:
                self.store.release_aggregate(authority, first_cursor)
        exported = set()
        for record in records:
            record.pop("lease_id", None)
            record.pop("window_id", None)
            readings = {reading["id"]: reading for reading in record["snapshot"]["readings"]}
            kept = set()
            for scope in record["snapshot"].get("roster", {}).get("scopes", []):
                for account in scope["accounts"]:
                    if "profile_binding" in account:
                        evidence = [readings.get(key) for key in account["reading_ids"]]
                        if not evidence or any(reading is None or not reading["windows"] or any(
                                window.get("unavailable_reason") is not None or window.get("last_known_reason") is not None
                                for window in reading["windows"]) for reading in evidence):
                            account.pop("profile_binding")
                    if "profile_binding" in account:
                        kept.update(account["reading_ids"])
                    else:
                        # Quota is exported only as evidence for an owner-bound account.
                        account["reading_ids"], account["canonical_ids"] = [], []
                bound = {account["id"] for account in scope["accounts"] if "profile_binding" in account}
                for consumer in scope["consumers"]:
                    consumer["reading_ids"] = []
                    if consumer.get("account_ids", [None])[0] not in bound:
                        consumer.pop("account_ids", None)
            record["snapshot"]["readings"] = [reading for reading in record["snapshot"]["readings"] if reading["id"] in kept]
            exported.update((record["publisher"], key) for key in kept)
        for source in sources:
            source.pop("inventory", None)
        document = {"version": 1, "complete": True, "incomplete": False,
                    "auth_revision": authorization, "records": records, "sources": sources,
                    "inventory": [entry for key, entry in assembly.inventory.items() if key in exported],
                    "stale_after_ms": STALE_MS,
                    "window_lease_ms": STALE_MS, "quota_unit": "percent", "model_mapping": "unknown"}
        if self.configuration is not None:
            # Catches source-local SPAWN edits before the next publication.
            roster = self.configuration()
            document["current_roster"] = dict(roster, scopes=[
                {key: value for key, value in scope.items() if key != "updated_at_ms"}
                for scope in roster["scopes"]])
            document["current_source_id"] = self.store.identity()["device_id"]
        now = self.store._now()
        deadlines = [now + min(120, limits["page_ttl_seconds"]) * 1000]
        for record in records:
            deadlines.append(record["snapshot"]["as_of_ms"] + STALE_MS)
            for reading in record["snapshot"]["readings"]:
                for window in reading["windows"]:
                    deadlines.append(window["observed_at_ms"] + STALE_MS)
                    if window.get("resets_at_ms") is not None:
                        deadlines.append(window["resets_at_ms"])
        raw = encode(document)
        if len(raw) > MAX_BYTES:
            raise ServiceError("capacity", 413)
        return raw, min(deadline for deadline in deadlines if deadline > now)

    def request(self, authority, payload):
        envelope = {"version": 1, "request_id": None, "op": None}
        try:
            if not authority.local:
                raise ServiceError("forbidden", 403)
            if not isinstance(payload, dict) or len(encode(payload)) > 4096:
                raise ServiceError("invalid_request")
            if not _opaque(payload.get("request_id")):
                raise ServiceError("invalid_request")
            envelope.update(request_id=payload["request_id"], op=payload.get("op"))
            op = payload.get("op")
            fields = {"version", "request_id", "op"}
            if op in ("page", "validate"):
                fields.add("revision")
            if op == "page":
                fields.add("cursor")
            if type(payload.get("version")) is not int or payload["version"] != 1 or op not in ("snapshot", "page", "validate") or set(payload) != fields:
                raise ServiceError("invalid_request")
            if op != "snapshot" and (not isinstance(payload["revision"], str) or not re.fullmatch(r"[0-9a-f]{64}", payload["revision"])):
                raise ServiceError("invalid_request")
            if op == "page" and not _opaque(payload["cursor"]):
                raise ServiceError("invalid_request")
            with self.store.transaction():
                # Opaque on the wire: consumers compare it for equality, never order it.
                authorization = str(self.store.authorization_revision(authority))
                settings = self.store.settings()
                now, wall = self.clock(), self.store._now()
                self.revoked = {key: expiry for key, expiry in self.revoked.items()
                                if expiry[0] > now and expiry[1] > wall}
                live = {}
                for key, value in self.sessions.items():
                    if value["deadline"] <= now or value["expires_at_ms"] <= wall:
                        continue
                    if value["auth_revision"] != authorization:
                        self.revoked[key] = (value["deadline"], value["expires_at_ms"])
                    else:
                        live[key] = value
                self.sessions = live
                # Bounded denial-only history, never retained payload/page accounting.
                while len(self.revoked) > 256:
                    del self.revoked[next(iter(self.revoked))]
                if not settings["capacity_enabled"]:
                    raise ServiceError("export_disabled" if op == "snapshot" else "export_revoked", 403)
                if payload.get("revision") in self.revoked:
                    raise ServiceError("export_revoked", 403)
                if op == "snapshot":
                    raw, expiry = self._document(authority, authorization)
                    revision = hashlib.sha256(raw).hexdigest()
                    fragments, start = [], 0
                    while start < len(raw):
                        end = min(start + PART_BYTES, len(raw))
                        while end < len(raw) and raw[end] & 0xC0 == 0x80:
                            end -= 1
                        fragments.append(raw[start:end].decode("utf-8"))
                        start = end
                    if len(fragments) > MAX_PAGES:
                        raise ServiceError("capacity", 413)
                    # Repeated snapshots of identical evidence cannot erase assembly progress.
                    session = self.sessions.get(revision)
                    if session is None:
                        total = sum(value["size"] for value in self.sessions.values())
                        if len(self.sessions) >= min(8, settings["max_page_sessions"]) or total + len(raw) > min(16 * MAX_BYTES, settings["max_page_storage_bytes"]):
                            raise ServiceError("capacity", 413)
                        issued = self.store._now()
                        ttl = (expiry - issued) / 1000
                        session = {"authority": authority, "auth_revision": authorization,
                                   "deadline": now + ttl, "issued_at_ms": issued, "expires_at_ms": expiry,
                                   "size": len(raw), "fragments": fragments, "tokens": [secrets.token_hex(24) for _ in fragments], "delivered": set()}
                        self.sessions[revision] = session
                    index = 0
                else:
                    revision = payload["revision"]
                    session = self.sessions.get(revision)
                    if session is None:
                        raise ServiceError("expired", 410)
                    if session["authority"] != authority or session["auth_revision"] != authorization:
                        raise ServiceError("export_revoked", 403)
                    if op == "validate":
                        if len(session["delivered"]) != len(session["fragments"]):
                            raise ServiceError("incomplete", 409)
                        current, _ = self._document(authority, authorization)
                        if hashlib.sha256(current).hexdigest() != revision:
                            raise ServiceError("evidence_changed", 409)
                        return {"response": {**envelope, "ok": True, "status": "current", "revision": revision,
                                "auth_revision": authorization, "validated_at_ms": self.store._now(), "expires_at_ms": session["expires_at_ms"]}}
                    try:
                        index = session["tokens"].index(payload["cursor"])
                    except ValueError:
                        raise ServiceError("expired", 410) from None
                session["delivered"].add(index)
                count = len(session["fragments"])
                return {"response": {**envelope, "ok": True, "status": "ok", "revision": revision,
                        **{key: session[key] for key in ("auth_revision", "issued_at_ms", "expires_at_ms", "size")},
                        "index": index, "count": count, "data": session["fragments"][index],
                        "next_cursor": session["tokens"][index + 1] if index + 1 < count else None,
                        "complete": index + 1 == count, "incomplete": False}}
        except ServiceError as exc:
            return {"response": {**envelope, "ok": False, "status": exc.code, "message": str(exc)}}
