"""Owner-local, integrity-checked display pages; no account grouping or clocks.

Complete Store revisions are validated before exposing any UTF-8 text. Immutable
sessions are bounded by the configured page budget and invalidated by authority
changes. Inventory snapshots retain observation times and conservatively use
as_of_ms=0 because inventory does not persist the original snapshot envelope.
"""
from __future__ import annotations

import hashlib
import secrets
import time

from .protocol import MAX_BODY, ServiceError, decode, encode, text, validate_snapshot
from .sync import _Assembly

PART_BYTES = 48 * 1024
PAGE_BYTES = 256 * 1024


class _CachedAssembly(_Assembly):
    """Display caches imported by pre-2.0 builds (Store._cached_snapshots)."""

    def _record(self, raw, *, charged=False):
        snapshot = validate_snapshot(raw)
        key = hashlib.sha256(encode(snapshot)).hexdigest()
        if key in self.records:
            raise ServiceError("conflict", 409)
        if len(self.records) >= self.limits["max_publishers"]:
            raise ServiceError("capacity", 413)
        if not charged:
            self._charge(len(encode(raw)))
        self.records[key] = snapshot


def _parts(snapshot):
    raw = encode(snapshot)
    fragments = []
    start = 0
    while start < len(raw):
        end = min(start + PART_BYTES, len(raw))
        while end < len(raw) and raw[end] & 0xC0 == 0x80:
            end -= 1
        fragments.append(raw[start:end].decode("utf-8"))
        start = end
    return [{"publisher": snapshot["publisher"], "index": index, "count": len(fragments),
             "size": len(raw), "data": fragment} for index, fragment in enumerate(fragments)]


class Display:
    def __init__(self, store, clock=time.monotonic):
        self.store = store
        self.clock = clock
        self.sessions = {}

    def _freeze(self, authority, limits):
        assembly, cached = _Assembly(limits), _CachedAssembly(limits)
        cursor = None
        while True:
            page = self.store.aggregate(authority, cursor, PAGE_BYTES)
            snapshots, chunks = page.get("cached_snapshots"), page.get("cached_chunks")
            if not isinstance(snapshots, list) or not isinstance(chunks, list):
                raise ServiceError("invalid_request")
            cursor = assembly.add(page, local_cache=True)
            for snapshot in snapshots:
                cached._record(snapshot)
            for chunk in chunks:
                cached._chunk(chunk)
            if assembly.size + cached.size > limits["max_total_bytes"]:
                raise ServiceError("capacity", 413)
            if cursor is None:
                break
        revision, records, sources = assembly.finish()
        if cached.chunks:
            raise ServiceError("conflict", 409)
        snapshots = [record["snapshot"] for record in records]
        present = {(record["publisher"], reading["id"]) for record in records for reading in record["snapshot"]["readings"]}
        retained = {}
        rosters = {record["publisher"]: record["snapshot"]["roster"] for record in records
                   if "roster" in record["snapshot"]}
        retained_rosters = {}
        for key, entry in assembly.inventory.items():
            reading = entry["reading"]
            measured_muse = reading["provider"] == "muse" and reading.get("agent_id") != "omp" and reading.get("usage_source") != "headless" and any(
                window.get("used") is not None and window.get("unavailable_reason") is None for window in reading["windows"])
            if key not in present or measured_muse:
                if measured_muse:
                    reading = dict(reading, usage_source="last-good")
                    if entry["publisher"] in rosters:
                        # Reuse only this publication's current SPAWN definitions.
                        # Direct reading IDs are source-local, not global identities.
                        retained_rosters[entry["publisher"]] = rosters[entry["publisher"]]
                retained.setdefault(entry["publisher"], []).append(reading)
        retained_count = 0
        for publisher, readings in retained.items():
            prefix = "usage-inventory:" + hashlib.sha256(publisher.encode()).hexdigest() + ":"
            batch = {"version": 3, "publisher": prefix + "0", "as_of_ms": 0, "readings": []}
            if publisher in retained_rosters:
                batch["roster"] = retained_rosters[publisher]
            size = len(encode(batch))
            index = 0
            for reading in readings:
                item_size = len(encode(reading)) + 1
                if batch["readings"] and (len(batch["readings"]) == 1000 or size + item_size > MAX_BODY - 128):
                    snapshots.append(validate_snapshot(batch))
                    index += 1
                    batch = {"version": 3, "publisher": prefix + str(index), "as_of_ms": 0, "readings": []}
                    if publisher in retained_rosters:
                        batch["roster"] = retained_rosters[publisher]
                    size = len(encode(batch))
                batch["readings"].append(reading)
                size += item_size
                retained_count += 1
            snapshots.append(validate_snapshot(batch))
        for key, snapshot in cached.records.items():
            snapshots.append(dict(snapshot, publisher="usage-cached:" + key))
        diagnostics = {"role": self.store.settings()["role"], "sources": len(sources), "snapshots": len(snapshots),
                       "retained_readings": retained_count, "cached_snapshots": len(cached.records),
                       "stale_sources": sum(source["status"] != "current" for source in sources)}
        base = {"revision": revision, "parts": [], "complete": False, "diagnostics": diagnostics}
        pages, page = [], dict(base, parts=[])
        size = len(encode(page)) + 128  # next cursor and owner RPC envelope
        for snapshot in snapshots:
            for part in _parts(snapshot):
                item_size = len(encode(part)) + 1
                if page["parts"] and size + item_size > PAGE_BYTES:
                    pages.append(page)
                    page = dict(base, parts=[])
                    size = len(encode(page)) + 128
                if size + item_size > PAGE_BYTES:
                    raise ServiceError("capacity", 413)
                page["parts"].append(part)
                size += item_size
        pages.append(page)
        tokens = [secrets.token_hex(24) for _ in pages]
        for index, page in enumerate(pages):
            page["complete"] = index == len(pages) - 1
            if not page["complete"]:
                page["next_cursor"] = tokens[index + 1]
        return tokens, pages

    def page(self, authority, payload):
        if not authority.local:
            raise ServiceError("forbidden", 403)
        if not isinstance(payload, dict) or set(payload) - {"cursor"}:
            raise ServiceError("invalid_request")
        revision = self.store.authorization_revision(authority)
        now = self.clock()
        self.sessions = {key: session for key, session in self.sessions.items()
                         if session["expires"] > now and session["authorization"] == revision}
        cursor = payload.get("cursor")
        if cursor is not None:
            cursor = text(cursor, 128)
            for session in self.sessions.values():
                if cursor in session["pages"]:
                    if session["authority"] != authority:
                        raise ServiceError("forbidden", 403)
                    # Copy through JSON so callers cannot mutate the frozen revision.
                    return decode(session["pages"][cursor])
            raise ServiceError("expired", 410)
        limits = self.store.settings()
        tokens, pages = self._freeze(authority, limits)
        total = sum(len(encode(page)) for page in pages)
        if total > limits["max_page_storage_bytes"]:
            raise ServiceError("capacity", 413)
        if len(pages) > 1:
            if len(self.sessions) >= limits["max_page_sessions"] or total + sum(s["size"] for s in self.sessions.values()) > limits["max_page_storage_bytes"]:
                raise ServiceError("capacity", 413)
            self.sessions[tokens[0]] = {"authorization": revision, "authority": authority,
                "expires": now + limits["page_ttl_seconds"], "size": total,
                "pages": {token:encode(page) for token,page in zip(tokens,pages)}}
        return pages[0]
