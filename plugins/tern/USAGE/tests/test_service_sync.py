"""Consumer-visible synchronization against real loopback TLS peers.

The fixture routes call actual Store/Security boundaries. Fault injection only
changes wire pages/replies, never the local projection or TLS implementation.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4
from unittest.mock import patch

from aiohttp import web

from usage_service.protocol import Authority, MAX_BODY, ServiceError, decode, encode
from usage_service.security import Security, bearer, secret, tls_context
from usage_service.store import Store
from usage_service.sync import PeerSync


def reading(key="account", padding=""):
    return {"id": key, "provider": "synthetic", "provider_label": "Synthetic",
            "source_label": "Fixture", "usage_source": "fixture", "plan": padding or "test",
            "windows": [{"key": "session", "pool": "fixture", "observed_at_ms": 1000,
                         "used": 25, "remaining": 75}]}


def snapshot(readings=None):
    return {"version": 3, "publisher": "assigned-by-store", "as_of_ms": 1000,
            "readings": [reading()] if readings is None else readings}


def page(*, revision="revision-1", records=None, sources=None, inventory=None,
         chunks=None, cursor=None, complete=True):
    return {"revision": revision, "records": records or [], "sources": sources or [],
            "inventory": inventory or [], "record_chunks": chunks or [],
            "next_cursor": cursor, "complete": complete, "incomplete": False}


def source(publication):
    return {"source_id": publication["subject_source_id"], "generation": publication["generation"],
            "profile_generation": publication["profile_generation"], "last_received_ms": 2000,
            "status": "stale", "clock_skew": False}


class TLSPeer:
    def __init__(self, root):
        self.root = root
        self.store = Store(root)
        self.security = Security(self.store, root)
        self.store.configure({"role": "hub", "export_enabled": True})
        self.runner = None
        self.calls = []
        self.pages = None
        self.pair_change = None
        self.fail_chunk = None
        self.aggregate_response = None
        self.block = None
        self.entered = asyncio.Event()
        self.after_page = None

    async def start(self, port=0):
        @web.middleware
        async def errors(request, handler):
            try:
                return await handler(request)
            except ServiceError as exc:
                return web.json_response(exc.public(), status=exc.status)

        app = web.Application(middlewares=[errors], client_max_size=MAX_BODY)
        app.router.add_route("*", "/{path:.*}", self.handle)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", port, ssl_context=tls_context(self.root))
        await site.start()
        self.port = site._server.sockets[0].getsockname()[1]
        self.endpoint = f"https://127.0.0.1:{self.port}"

    async def stop(self):
        if self.runner is not None:
            await self.runner.cleanup()
            self.runner = None

    def invitation(self):
        return self.security.offer(self.endpoint, self.store.identity()["group_id"])

    async def handle(self, request):
        path = request.path
        self.calls.append((request.method, path))
        if path == "/pair":
            body = decode(await request.read())
            result = {"ok": True, **self.security.consume(body["secret"], body["device_id"])}
            if self.pair_change:
                result.update(self.pair_change)
            return web.json_response(result)
        authority = self.security.authenticate(bearer(request.headers.get("Authorization")))
        if path == "/aggregate":
            self.entered.set()
            if self.block is not None:
                await self.block.wait()
            if self.aggregate_response:
                return self.aggregate_response()
            cursor = request.query.get("cursor")
            if self.pages is not None:
                result = self.pages[0 if cursor is None else int(cursor)]
                if isinstance(result, ServiceError):
                    raise result
            else:
                result = self.store.aggregate(authority, cursor=cursor, page_bytes=4096)
            if self.after_page:
                self.after_page(cursor)
            return web.json_response(result)
        body = await request.read()
        if path == "/publish":
            result = self.store.publish(authority, decode(body))
        elif path == "/policy":
            result = self.store.set_source_policy(authority, decode(body))
        elif path == "/pair/revoke":
            if decode(body) != {"device_id": authority.device_id}:
                raise ServiceError("forbidden", 403)
            result = self.store.revoke_peer(authority.device_id)
        else:
            raise ServiceError("not_found", 404)
        if path == "/publish":
            publication = result["publication"]
            result = {"ok": True, "accepted": True, "idempotent": result["idempotent"],
                      "publisher": publication["publisher"], "sequence": publication["sequence"]}
        return web.json_response(result)


class SyncTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.hub = TLSPeer(self.root / "hub")
        await self.hub.start()
        self.member = Store(self.root / "member")
        self.security = Security(self.member, self.root / "member")
        self.sync = PeerSync(self.member, self.security)
        self.extra = []

    async def asyncTearDown(self):
        await self.sync.close()
        for sync, store in self.extra:
            await sync.close()
            store.close()
        await self.hub.stop()
        self.member.close()
        self.hub.store.close()
        self.temp.cleanup()

    async def pair(self):
        return await self.sync.accept(self.hub.invitation())

    def records(self, store=None):
        store = store or self.member
        identity = store.identity()
        authority = Authority(identity["device_id"], identity["group_id"], local=True)
        result, cursor = [], None
        while True:
            response = store.aggregate(authority, cursor=cursor)
            self.assertFalse(response["record_chunks"], "fixture record too large for this helper")
            result.extend(response["records"])
            cursor = response.get("next_cursor")
            if cursor is None:
                return result

    def inventory(self, store=None):
        store = store or self.member
        identity = store.identity()
        authority = Authority(identity["device_id"], identity["group_id"], local=True)
        result, cursor = [], None
        while True:
            response = store.aggregate(authority, cursor=cursor)
            result.extend(response["inventory"])
            cursor = response.get("next_cursor")
            if cursor is None:
                return result

    async def publish(self, publication):
        return await self.sync._publish(self.sync._connection(), publication)

    async def seed(self):
        publication = self.hub.store.local_publish("host", snapshot())
        await self.pair()
        await self.sync.tick()
        self.assertEqual(self.records(), [publication])
        return publication

    async def assert_error(self, code, awaitable):
        with self.assertRaises(ServiceError) as caught:
            await awaitable
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    async def test_join_real_auth_and_export_consent(self):
        invitation = self.hub.invitation()
        result = await self.sync.accept(invitation)
        self.assertTrue(result["paired"])
        self.assertFalse(self.member.settings()["export_enabled"])
        connection = self.member.local_state("hub_connection")
        self.assertEqual(self.hub.security.authenticate(connection["credential"]).device_id,
                         self.member.identity()["device_id"])
        self.assertEqual(self.member.settings()["role"], "member")
        public = encode({"result": result, "diagnostics": self.sync.diagnostics()})
        for forbidden in (invitation["secret"], connection["credential"], str(self.root)):
            self.assertNotIn(forbidden.encode(), public)
        publication = self.member.local_publish("host", snapshot())
        await self.sync.tick()
        self.assertNotIn(publication, self.records(self.hub.store))
        await self.assert_error("forbidden", self.publish(publication))

    async def test_bad_invite_and_pin_never_send_pair_secret(self):
        invitation = self.hub.invitation()
        bad = invitation | {"endpoint": self.hub.endpoint + "/private/path"}
        await self.assert_error("invalid_request", self.sync.accept(bad))
        self.assertEqual(self.hub.calls, [])
        await self.assert_error("pin_mismatch", self.sync.accept(invitation | {"fingerprint": "00" * 32}))
        self.assertEqual(self.hub.calls, [])
        self.assertIsNone(self.member.local_state("hub_connection"))
        await self.sync.accept(invitation)

    async def test_pair_identity_mismatch_does_not_persist_and_releases_the_hub_pairing(self):
        member = self.member.identity()["device_id"]
        for change in ({"device_id": str(uuid4())}, {"group_id": "wrong"}, {"protocol": True}):
            with self.subTest(change=change):
                self.hub.pair_change = change
                await self.assert_error("incompatible_version", self.sync.accept(self.hub.invitation()))
                self.assertIsNone(self.member.local_state("hub_connection"))
                self.assertEqual(self.member.settings()["role"], "standalone")
                # The member revoked the credential it was issued, so a retry can pair.
                self.assertTrue(all(peer["revoked"] for peer in self.hub.store.peers() if peer["device_id"] == member))
        self.hub.pair_change = None
        self.assertTrue((await self.pair())["paired"])

    async def test_pre_2_0_record_accepted_by_hub_is_reissued_not_stuck_in_conflict(self):
        await self.pair()
        self.member.configure({"export_enabled": True})
        published = self.member.local_publish("host", snapshot([reading() | {"usage_source": "headless"}]))
        await self.sync.tick()
        # Rewrite both sides to what a pre-2.0 build stored: the legacy value and its body hash.
        legacy = encode(published).replace(b'"usage_source":"headless"', b'"usage_source":"native-headless"')
        self.assertNotEqual(legacy, encode(published))
        for store in (self.member, self.hub.store):
            with store.transaction() as db:
                db.execute("UPDATE snapshots SET payload=? WHERE publisher=?", (legacy, published["publisher"]))
                db.execute("UPDATE publishers SET body_hash=? WHERE publisher=?",
                           (hashlib.sha256(legacy).hexdigest(), published["publisher"]))
        await self.assert_error("conflict", self.sync.tick())
        # Reopening the store (every companion start) republishes it under the next sequence.
        await self.sync.close()
        self.member.close()
        self.member = Store(self.root / "member")
        self.sync = PeerSync(self.member, Security(self.member, self.root / "member"))
        await self.sync.tick()
        self.assertEqual(self.sync.diagnostics()["state"], "connected")
        [record] = [r for r in self.records(self.hub.store) if r["publisher"] == published["publisher"]]
        self.assertEqual(record["sequence"], published["sequence"] + 1)
        self.assertEqual(record["epoch"], published["epoch"])
        self.assertEqual(record["snapshot"]["readings"][0]["usage_source"], "headless")

    async def test_member_contribution_reaches_other_member_without_relay(self):
        await self.pair()
        self.member.configure({"export_enabled": True})
        own = self.member.local_publish("host", snapshot())
        hub = self.hub.store.local_publish("host", snapshot([reading("hub-account")]))
        await self.sync.tick()
        other = Store(self.root / "other")
        other_sync = PeerSync(other, Security(other, self.root / "other"))
        self.extra.append((other_sync, other))
        await other_sync.accept(self.hub.invitation())
        other.configure({"export_enabled": True})
        await other_sync.tick()
        self.assertEqual({r["publisher"] for r in self.records(other)}, {own["publisher"], hub["publisher"]})
        self.assertEqual(other.local_records(), [])
        before = len([call for call in self.hub.calls if call[1] == "/publish"])
        await other_sync.tick()
        self.assertEqual(len([call for call in self.hub.calls if call[1] == "/publish"]), before)
        self.assertEqual(self.member.local_records(), [own])
        await self.assert_error("forbidden", self.publish(hub))

    async def test_policy_forwarding_reaches_the_hub(self):
        await self.pair()
        self.member.configure({"export_enabled": True})
        identity = self.member.identity()
        authority = Authority(identity["device_id"], identity["group_id"], local=True)
        policy = {"source_id": identity["device_id"], "generation": identity["generation"],
                  "profile_generation": identity["profile_generation"],
                  "coordinator_id": identity["device_id"], "observers": {}, "profiles": {}}
        self.member.set_source_policy(authority, policy)
        await self.sync.tick()
        self.assertEqual(self.hub.store.source_policy(identity["device_id"]), policy)

    async def test_large_publication_is_one_post_and_failure_keeps_previous(self):
        await self.pair()
        self.member.configure({"export_enabled": True})
        first = self.member.local_publish("host", snapshot())
        await self.publish(first)
        second = self.member.local_publish("host", snapshot([reading(str(i), "x" * 1000) for i in range(90)]))
        with patch.object(self.hub.store, "publish", side_effect=ServiceError("capacity", 413)):
            await self.assert_error("capacity", self.publish(second))
        self.assertEqual(self.records(self.hub.store), [first])
        await self.publish(second)
        self.assertEqual(self.records(self.hub.store), [second])
        self.assertFalse(any(path.startswith("/uploads") for _, path in self.hub.calls))

    async def test_maximum_wire_publication_commits_without_response_overflow(self):
        await self.pair()
        self.member.configure({"export_enabled": True})
        publication = self.member.local_publish("maximum", snapshot([]))
        publication["sequence"] += 1
        readings = publication["snapshot"]["readings"]
        for index in range(1000):
            readings.append(reading(str(index), "x" * 1000))
            if len(encode(publication)) > MAX_BODY:
                readings.pop()
                break
        missing = MAX_BODY - len(encode(publication))
        for item in readings:
            extra = min(missing, 1024 - len(item["provider_label"]))
            item["provider_label"] += "x" * extra
            missing -= extra
            if not missing:
                break
        self.assertEqual(len(encode(publication)), MAX_BODY)
        await self.publish(publication)
        peer = self.hub.security.authenticate(self.member.local_state("hub_connection")["credential"])
        response = self.hub.store.aggregate(peer)
        self.assertTrue(response["record_chunks"])
        self.member.configure({"export_enabled": False})
        await self.sync.tick()
        # Own observer slots are never replaced by received remote copies.
        self.assertEqual(self.member.local_records()[0]["sequence"], publication["sequence"] - 1)

    async def test_real_chunked_aggregate_reassembles_observation_unchanged(self):
        publication = self.hub.store.local_publish("host", snapshot([reading(str(i), "x" * 1000) for i in range(90)]))
        await self.pair()
        await self.sync.tick()
        self.assertEqual(self.records(), [publication])
        self.assertGreater(sum(path == "/aggregate" for _, path in self.hub.calls), 2)
        self.assertEqual(self.records()[0]["snapshot"]["as_of_ms"], 1000)

    async def test_immutable_pages_ignore_concurrent_hub_update(self):
        first = self.hub.store.local_publish("host", snapshot([reading(str(i), "x" * 1000) for i in range(20)]))
        await self.pair()
        updated = []
        def update(cursor):
            if cursor is None and not updated:
                updated.append(self.hub.store.local_publish("host", snapshot([reading("new")])))
        self.hub.after_page = update
        await self.sync.tick()
        self.assertEqual(self.records(), [first])
        self.hub.after_page = None
        await self.sync.tick()
        self.assertEqual(self.records(), updated)

    async def test_malformed_partial_revision_and_duplicates_preserve_last_good(self):
        good = await self.seed()
        replacement = good | {"sequence": good["sequence"] + 1}
        raw = encode(replacement)
        chunk = {"record_id": hashlib.sha256(raw).hexdigest(), "index": 0, "count": 2,
                 "size": len(raw), "data": base64.b64encode(raw[:len(raw)//2]).decode()}
        inventory = {"publisher": good["publisher"], "observer_device_id": good["observer_device_id"],
                     "subject_source_id": good["subject_source_id"], "last_received_ms": 2000, "reading": reading()}
        faults = [
            [page(records=[replacement], sources=[source(good)], cursor="1", complete=False),
             page(revision="different")],
            [page(records=[replacement], sources=[source(good)], cursor="1", complete=False),
             ServiceError("expired", 410)],
            [page(chunks=[chunk], sources=[source(good)])],
            [page(chunks=[chunk, chunk], sources=[source(good)])],
            [page(records=[replacement, replacement], sources=[source(good)])],
            [page(sources=[source(good), source(good)])],
            [page(records=[replacement], sources=[source(good)], inventory=[inventory, inventory])],
            [page(records=[replacement])],
            [page() | {"records": {}}],
            [page() | {"incomplete": True}],
            [page(cursor="1", complete=True)],
            [page(records=[replacement], sources=[source(good)], cursor="1", complete=False),
             page(records=[replacement], cursor="1", complete=False)],
            [page(records=[replacement | {"sequence": good["sequence"] + 2, "snapshot": replacement["snapshot"] | {
                "readings": [reading() | {"windows": [reading()["windows"][0] | {"last_known_reason": []}]}]}}],
                  sources=[source(good)])],
        ]
        for pages in faults:
            with self.subTest(pages=pages):
                self.hub.pages = pages
                with self.assertRaises(ServiceError):
                    await self.sync.tick()
                self.assertEqual(self.records(), [good])
                self.assertEqual(self.sync.diagnostics()["state"], "disconnected")
        self.hub.pages = None
        await self.sync.tick()
        self.assertEqual(self.sync.diagnostics()["state"], "connected")

    async def test_chunk_hash_and_malformed_base64_preserve_last_good(self):
        good = await self.seed()
        raw = encode(good)
        for chunk in (
            {"record_id": "0" * 64, "index": 0, "count": 1, "size": len(raw), "data": base64.b64encode(raw).decode()},
            {"record_id": hashlib.sha256(raw).hexdigest(), "index": 0, "count": 1, "size": len(raw), "data": "!not-base64"},
        ):
            self.hub.pages = [page(chunks=[chunk], sources=[source(good)])]
            with self.assertRaises(ServiceError):
                await self.sync.tick()
            self.assertEqual(self.records(), [good])

    async def test_inventory_survives_missing_readings_and_source_removal_is_explicit(self):
        first = self.hub.store.local_publish("host", snapshot())
        latest = self.hub.store.local_publish("host", snapshot([]))
        await self.pair()
        await self.sync.tick()
        self.assertEqual(self.records(), [latest])
        self.assertEqual([entry["reading"] for entry in self.inventory()], first["snapshot"]["readings"])
        self.hub.pages = [page(revision="explicit-empty")]
        await self.sync.tick()
        self.assertEqual(self.records(), [])
        self.assertEqual(self.inventory(), [])

    async def test_auth_rejection_pin_change_disconnect_and_reconnect_keep_last_good(self):
        good = await self.seed()
        connection = self.member.local_state("hub_connection")
        self.member.set_local_state("hub_connection", connection | {"credential": secret()})
        await self.assert_error("unauthorized", self.sync.tick())
        self.assertEqual(self.records(), [good])
        self.member.set_local_state("hub_connection", connection | {"fingerprint": "00" * 32})
        await self.assert_error("pin_mismatch", self.sync.tick())
        self.assertEqual(self.records(), [good])
        self.member.set_local_state("hub_connection", connection)
        port = self.hub.port
        await self.hub.stop()
        await self.assert_error("source_unreachable", self.sync.tick())
        self.assertEqual(self.records(), [good])
        await self.hub.start(port)
        await self.sync.tick()
        self.assertEqual(self.records(), [good])
        self.assertEqual(self.sync.diagnostics()["state"], "connected")

    async def test_redirect_oversized_and_raw_error_never_leak(self):
        good = await self.seed()
        sentinel = "PRIVATE-TOKEN-/home/fixture-secret"
        responses = [
            lambda: web.Response(status=302, headers={"Location": self.hub.endpoint + "/stolen"}),
            lambda: web.Response(body=b"x" * (MAX_BODY + 1)),
            lambda: web.Response(body=b"{invalid"),
            lambda: web.json_response({"ok": False, "error": {"code": sentinel, "message": sentinel}}, status=500),
        ]
        for response in responses:
            self.hub.aggregate_response = response
            with self.assertRaises(ServiceError) as caught:
                await self.sync.tick()
            self.assertNotIn(sentinel, str(caught.exception))
            self.assertNotIn(sentinel, str(self.sync.diagnostics()))
            self.assertEqual(self.records(), [good])
        self.assertFalse(any(path == "/stolen" for _, path in self.hub.calls))

    async def test_proxy_environment_is_ignored(self):
        with patch.dict(os.environ, {"HTTPS_PROXY": "http://127.0.0.1:1",
                                     "ALL_PROXY": "http://127.0.0.1:1", "NO_PROXY": ""}):
            await self.seed()
        self.assertEqual(self.sync.diagnostics()["state"], "connected")

    async def test_revocation_mid_page_preserves_previous_projection(self):
        good = await self.seed()
        self.hub.store.local_publish("host", snapshot([reading(str(i), "x" * 1000) for i in range(20)]))
        own = self.member.identity()["device_id"]
        def revoke(cursor):
            if cursor is None:
                self.hub.store.revoke_peer(own)
        self.hub.after_page = revoke
        await self.assert_error("unauthorized", self.sync.tick())
        self.assertEqual(self.records(), [good])

    async def test_capacity_failure_does_not_truncate_last_good(self):
        good = await self.seed()
        self.member.configure({"max_sources": 2})
        second_source = source(good) | {"source_id": str(uuid4())}
        third_source = source(good) | {"source_id": str(uuid4())}
        self.hub.pages = [page(records=[good], sources=[source(good), second_source, third_source])]
        await self.assert_error("capacity", self.sync.tick())
        self.assertEqual(self.records(), [good])

    async def test_total_assembly_budget_preserves_last_good(self):
        good = await self.seed()
        self.member.configure({"max_total_bytes": 4096})
        replacement = good | {"sequence": good["sequence"] + 1,
                              "snapshot": good["snapshot"] | {
                                  "readings": [reading(str(index), "x" * 1000) for index in range(10)]}}
        self.hub.pages = [page(records=[replacement], sources=[source(good)])]
        await self.assert_error("capacity", self.sync.tick())
        self.assertEqual(self.records(), [good])

    async def test_tick_single_flight_and_background_recovery(self):
        good = await self.seed()
        self.hub.block = asyncio.Event()
        self.hub.entered.clear()
        running = asyncio.create_task(self.sync.tick())
        await asyncio.wait_for(self.hub.entered.wait(), 2)
        before = len(self.hub.calls)
        await self.sync.tick()
        self.assertEqual(len(self.hub.calls), before)
        self.hub.block.set()
        await running
        self.hub.block = None
        self.hub.aggregate_response = lambda: web.Response(status=503, body=b"{}")
        with patch("usage_service.sync.POLL_SECONDS", 0.01):
            await self.sync.start()
            for _ in range(100):
                if self.sync.diagnostics()["state"] == "disconnected":
                    break
                await asyncio.sleep(0.01)
            self.assertEqual(self.sync.diagnostics()["state"], "disconnected")
            self.hub.aggregate_response = None
            for _ in range(100):
                if self.sync.diagnostics()["state"] == "connected":
                    break
                await asyncio.sleep(0.01)
            self.assertEqual(self.sync.diagnostics()["state"], "connected")
            await self.sync.close()
        self.assertEqual(self.records(), [good])

    async def test_unpair_revokes_remote_authority_and_works_offline(self):
        await self.seed()
        own = self.member.local_publish("own", snapshot())
        credential = self.member.local_state("hub_connection")["credential"]
        result = await self.sync.unpair()
        self.assertTrue(result["remote_revoked"])
        self.assertIn("cannot be recalled", result["notice"])
        self.assertIsNone(self.member.local_state("hub_connection"))
        self.assertEqual(self.records(), [own])
        with self.assertRaises(ServiceError):
            self.hub.security.authenticate(credential)
        await self.pair()
        await self.sync.tick()
        await self.hub.stop()
        result = await self.sync.unpair()
        self.assertFalse(result["remote_revoked"])
        self.assertIsNone(self.member.local_state("hub_connection"))
        self.assertEqual(self.records(), [own])
        self.assertEqual(self.member.settings()["role"], "standalone")


if __name__ == "__main__":
    unittest.main()
