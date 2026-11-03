"""Pinned peer transport and all-or-nothing remote projection.

Only authenticated, complete immutable revisions enter Store.replace_remote.
Ordinary polling recovers on the next interval; there is no alternate coordinator,
redirect, insecure retry, or publication of the received remote projection.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import re
import time
from contextlib import suppress

import aiohttp

from .protocol import (CHUNK_BYTES, MAX_BODY, MESSAGES, PROTOCOL, ServiceError,
                       decode, encode, identifier, integer, text,
                       validate_publication, validate_snapshot)
from .security import endpoint, pin, validate_invitation, verifier

POLL_SECONDS = 5
REQUEST_TIMEOUT = aiohttp.ClientTimeout(total=15, connect=5, sock_read=10)


def _opaque(value, maximum=256):
    value = text(value, maximum)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", value):
        raise ServiceError("invalid_request")
    return value


class _Assembly:
    """Bounded per-fetch state, discarded on any shape/integrity/page failure."""

    def __init__(self, limits):
        self.limits = limits
        self.revision = None
        self.records = {}
        self.sources = {}
        self.inventory = {}
        self.chunks = {}
        self.completed_chunks = set()
        self.cursors = set()
        self.size = 0
        self.wire_size = 0

    def _charge(self, size):
        self.size += size
        if self.size > self.limits["max_total_bytes"]:
            raise ServiceError("capacity", 413)

    def _record(self, raw, *, charged=False):
        publication = validate_publication(raw)
        publisher = publication["publisher"]
        if not publisher.startswith(publication["observer_device_id"] + ":"):
            raise ServiceError("forbidden", 403)
        if publisher in self.records:
            raise ServiceError("conflict", 409)
        if len(self.records) >= self.limits["max_publishers"]:
            raise ServiceError("capacity", 413)
        if not charged:
            self._charge(len(encode(raw)))
        self.records[publisher] = publication

    def _chunk(self, chunk):
        if not isinstance(chunk, dict) or set(chunk) != {"record_id", "index", "count", "size", "data"}:
            raise ServiceError("invalid_request")
        record_id = chunk["record_id"]
        if not isinstance(record_id, str) or not re.fullmatch(r"[0-9a-f]{64}", record_id):
            raise ServiceError("invalid_request")
        size = integer(chunk["size"], 1, MAX_BODY)
        count = integer(chunk["count"], 1, size)
        index = integer(chunk["index"], 0, count - 1)
        if record_id in self.completed_chunks:
            raise ServiceError("conflict", 409)
        if not isinstance(chunk["data"], str):
            raise ServiceError("invalid_request")
        try:
            data = base64.b64decode(chunk["data"], validate=True)
        except (ValueError, binascii.Error):
            raise ServiceError("invalid_request") from None
        if not data or len(data) > CHUNK_BYTES:
            raise ServiceError("invalid_request")
        if record_id not in self.chunks:
            if len(self.chunks) + len(self.records) >= self.limits["max_publishers"]:
                raise ServiceError("capacity", 413)
            self._charge(size)
            self.chunks[record_id] = {"size": size, "count": count, "parts": {}, "received": 0}
        state = self.chunks[record_id]
        if state["size"] != size or state["count"] != count or index in state["parts"]:
            raise ServiceError("conflict", 409)
        state["received"] += len(data)
        if state["received"] > size:
            raise ServiceError("invalid_request")
        state["parts"][index] = data
        if len(state["parts"]) == count:
            raw = b"".join(state["parts"][i] for i in range(count))
            if len(raw) != size or hashlib.sha256(raw).hexdigest() != record_id:
                raise ServiceError("conflict", 409)
            self._record(decode(raw), charged=True)
            del self.chunks[record_id]
            self.completed_chunks.add(record_id)

    def add(self, page, *, local_cache=False):
        if not isinstance(page, dict):
            raise ServiceError("invalid_request")
        revision = _opaque(page.get("revision"))
        if self.revision is None:
            self.revision = revision
        elif revision != self.revision:
            raise ServiceError("conflict", 409)
        if page.get("incomplete") is not False:
            raise ServiceError("capacity", 413)
        complete = page.get("complete")
        cursor = page.get("next_cursor")
        if not isinstance(complete, bool) or complete != (cursor is None):
            raise ServiceError("invalid_request")
        if cursor is not None:
            cursor = _opaque(cursor)
            if cursor in self.cursors:
                raise ServiceError("conflict", 409)
            self.cursors.add(cursor)
        fields = ("records", "sources", "inventory", "record_chunks")
        if any(not isinstance(page.get(field), list) for field in fields):
            raise ServiceError("invalid_request")
        if not complete and not any(page[field] for field in fields) and not (
                local_cache and (page.get("cached_snapshots") or page.get("cached_chunks"))):
            raise ServiceError("invalid_request")
        self.wire_size += len(encode(page))
        # Includes base64 and framing, even for adversarial one-byte chunks.
        if self.wire_size > 4 * self.limits["max_total_bytes"] + MAX_BODY:
            raise ServiceError("capacity", 413)
        for record in page["records"]:
            self._record(record)
        for chunk in page["record_chunks"]:
            self._chunk(chunk)
        for source in page["sources"]:
            if not isinstance(source, dict) or "inventory" in source:
                raise ServiceError("invalid_request")
            source_id = identifier(source.get("source_id"))
            if source_id in self.sources:
                raise ServiceError("conflict", 409)
            if len(self.sources) >= self.limits["max_sources"]:
                raise ServiceError("capacity", 413)
            if source.get("status") not in ("current", "stale", "offline", "not_yet_measured", "source_unreachable"):
                raise ServiceError("invalid_request")
            if not isinstance(source.get("clock_skew"), bool):
                raise ServiceError("invalid_request")
            normalized = {"source_id": source_id, "status": source["status"],
                          "last_received_ms": None if source.get("last_received_ms") is None else integer(source["last_received_ms"]),
                          "clock_skew": source["clock_skew"], "inventory": []}
            if "generation" in source:
                normalized["generation"] = identifier(source["generation"])
            if "profile_generation" in source:
                normalized["profile_generation"] = integer(source["profile_generation"])
            self._charge(len(encode(source)))
            self.sources[source_id] = normalized
        for entry in page["inventory"]:
            if not isinstance(entry, dict):
                raise ServiceError("invalid_request")
            observer = identifier(entry.get("observer_device_id"))
            source_id = identifier(entry.get("subject_source_id"))
            publisher = text(entry.get("publisher"), 512)
            if not publisher.startswith(observer + ":"):
                raise ServiceError("forbidden", 403)
            reading = validate_snapshot({"version": 3, "publisher": publisher, "as_of_ms": 0,
                                         "readings": [entry.get("reading")]})["readings"][0]
            key = (publisher, reading["id"])
            if key in self.inventory:
                raise ServiceError("conflict", 409)
            if len(self.inventory) >= self.limits["max_inventory"]:
                raise ServiceError("capacity", 413)
            self._charge(len(encode(entry)))
            self.inventory[key] = {"publisher": publisher, "observer_device_id": observer,
                                   "subject_source_id": source_id, "reading": reading,
                                   "last_received_ms": integer(entry.get("last_received_ms"))}
        return cursor

    def finish(self):
        if self.chunks:
            raise ServiceError("conflict", 409)
        for record in self.records.values():
            if record["subject_source_id"] not in self.sources:
                raise ServiceError("invalid_request")
        for entry in self.inventory.values():
            source = self.sources.get(entry["subject_source_id"])
            if source is None:
                raise ServiceError("invalid_request")
            source["inventory"].append(entry)
        return self.revision, list(self.records.values()), list(self.sources.values())


class PeerSync:
    def __init__(self, store, security):
        self.store = store
        self.security = security
        self._session = None
        self._fingerprints = {}
        self._task = None
        self._lock = asyncio.Lock()
        self._state = "disconnected" if store.local_state("hub_connection") else "unpaired"
        self._error = None
        self._last_success_ms = None

    def diagnostics(self):
        return {"state": self._state, "error": self._error, "last_success_ms": self._last_success_ms}

    async def start(self):
        if self._task is None:
            self._task = asyncio.create_task(self._poll(), name="usage-peer-sync")

    async def close(self):
        if self._task is not None:
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        async with self._lock:
            if self._session is not None:
                await self._session.close()
                self._session = None

    async def _poll(self):
        while True:
            try:
                await self.tick()
            except ServiceError:
                # tick records the fixed public error; no raw transport logging.
                pass
            await asyncio.sleep(POLL_SECONDS)

    def _connection(self):
        connection = self.store.local_state("hub_connection")
        if not isinstance(connection, dict) or set(connection) != {"endpoint", "fingerprint", "credential", "device_id", "group_id"}:
            raise ServiceError("setup_required", 503)
        endpoint(connection["endpoint"])
        pin(connection["fingerprint"])
        verifier(connection["credential"])
        identifier(connection["device_id"])
        _opaque(connection["group_id"], 128)
        if connection["group_id"] != self.store.identity()["group_id"]:
            raise ServiceError("forbidden", 403)
        return connection

    def _fingerprint(self, fingerprint):
        # One instance per pin: aiohttp keys its connection pool on the ssl argument.
        pinned = pin(fingerprint)
        if pinned not in self._fingerprints:
            self._fingerprints[pinned] = aiohttp.Fingerprint(pinned)
        return self._fingerprints[pinned]

    async def _request(self, connection, method, path, *, body=None, params=None, pairing=False):
        if self._session is None:
            self._session = aiohttp.ClientSession(
                connector=aiohttp.TCPConnector(limit=8, limit_per_host=8),
                timeout=REQUEST_TIMEOUT, trust_env=False,
                cookie_jar=aiohttp.DummyCookieJar(), auto_decompress=False)
        data = encode(body) if body is not None else None
        if data is not None and len(data) > MAX_BODY:
            raise ServiceError("snapshot_too_large", 413)
        headers = {"Accept": "application/json", "Accept-Encoding": "identity"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        if not pairing:
            headers["Authorization"] = "Bearer " + connection["credential"]
        try:
            async with self._session.request(
                method, endpoint(connection["endpoint"]) + path, data=data, params=params,
                headers=headers, ssl=self._fingerprint(connection["fingerprint"]), allow_redirects=False,
            ) as response:
                if 300 <= response.status < 400:
                    raise ServiceError("source_unreachable", 503)
                if response.content_length is not None and response.content_length > MAX_BODY:
                    raise ServiceError("snapshot_too_large", 413)
                data = bytearray()
                async for piece in response.content.iter_chunked(CHUNK_BYTES):
                    if len(data) + len(piece) > MAX_BODY:
                        raise ServiceError("snapshot_too_large", 413)
                    data.extend(piece)
                result = decode(bytes(data))
                if not isinstance(result, dict):
                    raise ServiceError("invalid_request")
                if response.status >= 400 or result.get("ok") is False:
                    error = result.get("error")
                    code = error.get("code") if isinstance(error, dict) else None
                    if not isinstance(code, str) or code not in MESSAGES:
                        code = "unauthorized" if response.status == 401 else "source_unreachable"
                    raise ServiceError(code, response.status if response.status >= 400 else 400)
                return result
        except aiohttp.ServerFingerprintMismatch:
            raise ServiceError("pin_mismatch", 403) from None
        except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
            raise ServiceError("source_unreachable", 503) from None

    async def accept(self, invitation):
        invitation = validate_invitation(invitation)
        async with self._lock:
            if self.store.local_state("hub_connection"):
                raise ServiceError("conflict", 409)
            own = self.store.identity()["device_id"]
            if invitation["device_id"] == own:
                raise ServiceError("forbidden", 403)
            reply = await self._request(invitation, "POST", "/pair", pairing=True,
                                        body={"secret": invitation["secret"], "device_id": own})
            credential = reply.get("credential")
            try:
                if (reply.get("ok") is not True or type(reply.get("protocol")) is not int
                        or reply["protocol"] != PROTOCOL or reply.get("device_id") != invitation["device_id"]
                        or reply.get("group_id") != invitation["group_id"]):
                    raise ServiceError("incompatible_version", 409)
                verifier(credential)
                connection = {key: invitation[key] for key in ("endpoint", "fingerprint", "device_id", "group_id")}
                connection["credential"] = credential
                with self.store.transaction():
                    self.store.configure({"role": "member", "group_id": invitation["group_id"]})
                    self.store.set_local_state("hub_connection", connection)
            except BaseException:
                # The hub already committed this pairing; release it so a retry can pair.
                await self._revoke_issued(invitation, credential)
                raise
            self._state, self._error = "paired", None
            return {"paired": True, "device_id": invitation["device_id"],
                    "group_id": invitation["group_id"], "fingerprint": invitation["fingerprint"]}

    async def _revoke_issued(self, invitation, credential):
        try:
            verifier(credential)
            await self._request(dict(invitation, credential=credential), "POST", "/pair/revoke",
                                body={"device_id": self.store.identity()["device_id"]})
        except ServiceError:
            # Best effort: an unreachable hub keeps the pairing until its owner revokes it.
            pass

    async def _publish(self, connection, publication):
        publication = validate_publication(publication)
        own = self.store.identity()["device_id"]
        if publication["observer_device_id"] != own or not publication["publisher"].startswith(own + ":"):
            raise ServiceError("forbidden", 403)
        if not self.store.settings()["export_enabled"]:
            raise ServiceError("forbidden", 403)
        reply = await self._request(connection, "POST", "/publish", body=publication)
        if (reply.get("ok") is not True or not isinstance(reply.get("idempotent"), bool)
                or reply.get("publisher") != publication["publisher"]
                or type(reply.get("sequence")) is not int or reply["sequence"] != publication["sequence"]):
            raise ServiceError("invalid_request")
        return {"ok": True, "idempotent": reply["idempotent"]}

    async def tick(self):
        # Concurrent callers wait for one flight rather than starting a second fetch.
        if self._lock.locked():
            return self.diagnostics()
        async with self._lock:
            if not self.store.local_state("hub_connection"):
                self._state, self._error = "unpaired", None
                return self.diagnostics()
            try:
                async with asyncio.timeout(60):
                    connection = self._connection()
                    settings = self.store.settings()
                    if settings["paused"]:
                        self._state, self._error = "paused", None
                        return self.diagnostics()
                    policy = self.store.source_policy()
                    if settings["export_enabled"] and policy is not None:
                        if policy["source_id"] != self.store.identity()["device_id"]:
                            raise ServiceError("forbidden", 403)
                        await self._request(connection, "POST", "/policy", body=policy)
                    if settings["export_enabled"]:
                        for publication in self.store.local_records():
                            # Pre-2.0 builds could store delegated "active" records; never replay them.
                            if publication["kind"] != "active":
                                await self._publish(connection, publication)
                    assembly = _Assembly(settings)
                    cursor = None
                    while True:
                        page = await self._request(connection, "GET", "/aggregate",
                                                   params={"cursor": cursor} if cursor is not None else None)
                        cursor = assembly.add(page)
                        if cursor is None:
                            break
                    revision, records, sources = assembly.finish()
                    self.store.replace_remote(connection["device_id"], revision, records, sources)
                    self._last_success_ms = int(time.time() * 1000)
                    self._state, self._error = "connected", None
            except (ServiceError, asyncio.TimeoutError) as exc:
                error = exc if isinstance(exc, ServiceError) else ServiceError("source_unreachable", 503)
                self._state, self._error = "disconnected", error.code
                raise error from None
            return self.diagnostics()

    async def usage_operation(self, operation, payload):
        if operation not in {"usage_refresh", "usage_status", "usage_preferences"}:
            raise ServiceError("invalid_request")
        # These short control requests must not queue behind a full aggregate sync.
        reply = await self._request(self._connection(), "POST", "/usage/" + operation, body=payload)
        if operation == "usage_preferences":
            from .refresh import validate_preferences
            value = {"refresh_interval_seconds": reply.get("refresh_interval_seconds")}
            validate_preferences(value)
            return value
        if reply.get("state") not in {"running", "idle"}:
            raise ServiceError("invalid_request")
        result = {"state": reply["state"]}
        for field in ("requested_at_ms", "last_completed_ms", "completed", "total"):
            result[field] = integer(reply.get(field))
        failures = reply.get("failures", [])
        if not isinstance(failures, list) or len(failures) > 128:
            raise ServiceError("invalid_request")
        result["failures"] = []
        for failure in failures:
            if not isinstance(failure, dict) or not isinstance(failure.get("code"), str):
                raise ServiceError("invalid_request")
            result["failures"].append({"code": text(failure["code"], 128),
                **({"account": text(failure["account"], 256)} if "account" in failure else {})})
        return result

    async def unpair(self):
        async with self._lock:
            connection = self.store.local_state("hub_connection")
            revoked = False
            if connection is not None:
                try:
                    reply = await self._request(self._connection(), "POST", "/pair/revoke",
                                                body={"device_id": self.store.identity()["device_id"]})
                    revoked = reply.get("ok") is True
                except ServiceError:
                    # Explicit local unpair must still work offline; disclose remote status.
                    revoked = False
                with self.store.transaction():
                    self.store.revoke_peer(identifier(connection.get("device_id")))
                    self.store.set_local_state("hub_connection", None)
                    self.store.configure({"role": "standalone", "group_id": self.store.identity()["device_id"]})
            self._state, self._error, self._last_success_ms = "unpaired", None, None
            return {"unpaired": True, "remote_revoked": revoked,
                    "notice": "Already received data cannot be recalled from other installations."}
