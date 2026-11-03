"""Consumer-visible persistence, authority and complete-projection invariants."""
from __future__ import annotations

import base64
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import hashlib
import multiprocessing
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4

from usage_service.protocol import Authority, MAX_BODY, ServiceError, decode, encode
from usage_service.store import Store


class Clock:
    def __init__(self):
        self.value = 1_800_000_000.0

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


def reading(name="account", label="Synthetic"):
    return {"id": name, "provider": "synthetic", "provider_label": label,
            "source_label": "Fixture source", "usage_source": "passive",
            "canonical_id": "synthetic:tenant:" + name, "windows": []}


def snapshot(readings=None, observed=1_800_000_000_000):
    return {"version": 3, "publisher": "replaced-locally", "as_of_ms": observed,
            "readings": [reading()] if readings is None else readings}


def publication(device, generation=None, key="window", sequence=1, epoch=None, source=None, readings=None, observed=1_800_000_000_000):
    publisher = device + ":" + key
    return {"protocol": 1, "observer_device_id": device, "subject_source_id": source or device,
            "publisher": publisher, "epoch": epoch or str(uuid4()), "sequence": sequence,
            "generation": generation or str(uuid4()), "profile_generation": 0, "kind": "passive",
            "snapshot": snapshot(readings, observed) | {"publisher": publisher}}


def cold_writer(root, key, result):
    """A real independent process, not an in-memory store substitute."""
    try:
        store = Store(Path(root))
        for index in range(8):
            store.local_publish(key, snapshot([reading(key)], observed=index))
        result.put(("ok", store.identity()["device_id"]))
        store.close()
    except Exception as exc:
        result.put(("error", type(exc).__name__))


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "private"
        self.clock = Clock()
        self.store = Store(self.root, clock=self.clock)
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(lambda: self.store.close())

    def owner(self):
        identity = self.store.identity()
        return Authority(identity["device_id"], identity["group_id"], "owner", True)

    def peer(self, device=None):
        device = device or str(uuid4())
        token = hashlib.sha256(str(uuid4()).encode()).hexdigest()
        credential = hashlib.sha256(str(uuid4()).encode()).hexdigest()
        self.store.create_invitation(token, int(self.clock() * 1000) + 600_000, self.owner().group_id)
        self.store.consume_invitation(token, int(self.clock() * 1000), device, credential)
        return Authority(device, self.owner().group_id)

    def assert_error(self, code, operation, *args, **kwargs):
        with self.assertRaises(ServiceError) as caught:
            operation(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def complete_view(self, authority=None, page_bytes=262144):
        authority = authority or self.owner()
        page = self.store.aggregate(authority, page_bytes=page_bytes)
        result = {"records": [], "sources": [], "inventory": []}
        chunks, revision = {}, page["revision"]
        while True:
            self.assertEqual(page["revision"], revision)
            self.assertLessEqual(len(encode(page)), MAX_BODY)
            self.assertFalse(page["incomplete"])
            for field in result:
                result[field].extend(page[field])
            for chunk in page["record_chunks"]:
                entry = chunks.setdefault(chunk["record_id"], {"count": chunk["count"], "size": chunk["size"], "parts": {}})
                self.assertEqual(entry["count"], chunk["count"])
                self.assertEqual(entry["size"], chunk["size"])
                entry["parts"][chunk["index"]] = base64.b64decode(chunk["data"], validate=True)
            if page["complete"]:
                self.assertIsNone(page["next_cursor"])
                break
            self.assertIsNotNone(page["next_cursor"])
            page = self.store.aggregate(authority, page["next_cursor"])
        for record_id, entry in chunks.items():
            self.assertEqual(set(entry["parts"]), set(range(entry["count"])))
            raw = b"".join(entry["parts"][index] for index in range(entry["count"]))
            self.assertEqual(len(raw), entry["size"])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), record_id)
            result["records"].append(decode(raw))
        return result

    def source_policy(self, observers):
        policy = self.store.source_policy()
        policy["profile_generation"] += 1
        policy["profiles"] = {"profile-main": {"generation": 1, "canonical_ids": ["synthetic:tenant:account"]}}
        policy["observers"] = {observer.device_id: ["profile-main"] for observer in observers}
        return self.store.set_source_policy(self.owner(), policy)

    def foreign_publication(self, observer, policy, sequence=1, epoch=None):
        record = publication(observer.device_id, policy["generation"], source=policy["source_id"], sequence=sequence, epoch=epoch)
        record["profile_generation"] = policy["profile_generation"]
        record["profile_handles"] = ["profile-main"]
        return record

    def test_private_defaults_and_stable_identity(self):
        identity = self.store.identity()
        self.assertEqual(self.store.settings()["role"], "standalone")
        self.assertFalse(self.store.settings()["export_enabled"])
        self.assertFalse(self.store.settings()["metadata_enabled"])
        self.assertIsNone(self.store.settings()["sharing_bind"])
        self.store.close()
        self.store = Store(self.root, clock=self.clock)
        self.assertEqual(self.store.identity(), identity)

    def test_atomic_nested_transaction_rollback(self):
        other = Store(Path(self.temp.name) / "nested", clock=self.clock)
        self.addCleanup(other.close)
        with self.assertRaisesRegex(RuntimeError, "interrupt"):
            with other.transaction():
                other.configure({"paused": True})
                other.set_local_state("setup_consent", {"secret_path": "/private/profile"})
                other.local_publish("import", snapshot(observed=42))
                raise RuntimeError("interrupt")
        self.assertFalse(other.settings()["paused"])
        self.assertIsNone(other.local_state("setup_consent"))
        self.assertEqual(other.local_records(), [])

    def test_two_independent_connections_keep_every_publisher_and_sequence(self):
        other = Store(self.root, clock=self.clock)
        self.addCleanup(other.close)
        def write(store, key):
            for index in range(15):
                store.local_publish(key, snapshot([reading(key)], observed=index))
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(write, self.store, "first")
            second = pool.submit(write, other, "second")
            first.result()
            second.result()
        records = self.store.local_records()
        self.assertEqual(len(records), 2)
        self.assertEqual({record["sequence"] for record in records}, {15})
        self.assertEqual({record["snapshot"]["as_of_ms"] for record in records}, {14})

    def test_concurrent_cold_processes_choose_one_identity_without_publisher_loss(self):
        context = multiprocessing.get_context("spawn")
        results = context.Queue()
        root = str(Path(self.temp.name) / "cold")
        processes = [context.Process(target=cold_writer, args=(root, key, results)) for key in ("one", "two", "three")]
        for process in processes:
            process.start()
        outcomes = [results.get(timeout=45) for _ in processes]
        for process in processes:
            process.join(45)
            self.assertEqual(process.exitcode, 0)
        self.assertEqual({outcome[0] for outcome in outcomes}, {"ok"})
        self.assertEqual(len({outcome[1] for outcome in outcomes}), 1)
        cold = Store(Path(root))
        self.addCleanup(cold.close)
        self.assertEqual(len(cold.local_records()), 3)
        self.assertEqual({record["sequence"] for record in cold.local_records()}, {8})
        results.close()

    def test_sequences_epochs_conflicts_and_timestamps_are_independent(self):
        peer = self.peer()
        first = publication(peer.device_id, sequence=4, observed=17)
        self.store.publish(peer, first)
        duplicate = self.store.publish(peer, first)
        self.assertTrue(duplicate["idempotent"])
        self.assert_error("conflict", self.store.publish, peer, first | {"snapshot": first["snapshot"] | {"as_of_ms": 18}})
        self.assert_error("replay", self.store.publish, peer, first | {"sequence": 3})
        second = first | {"epoch": str(uuid4()), "sequence": 1}
        self.store.publish(peer, second)
        self.assert_error("replay", self.store.publish, peer, first | {"sequence": 100})
        independent = publication(peer.device_id, key="other", observed=19)
        self.store.publish(peer, independent)
        self.assertEqual({record["snapshot"]["as_of_ms"] for record in self.complete_view()["records"]}, {17, 19})

    def test_publisher_device_and_group_spoofing_never_replaces_good_state(self):
        peer, attacker = self.peer(), self.peer()
        good = publication(peer.device_id)
        self.store.publish(peer, good)
        self.assert_error("forbidden", self.store.publish, attacker, good)
        spoof = good | {"observer_device_id": attacker.device_id}
        self.assert_error("forbidden", self.store.publish, attacker, spoof)
        self.assert_error("unauthorized", self.store.aggregate, Authority(peer.device_id, "other-group"))
        self.assertEqual(self.complete_view()["records"], [good])

    def test_inventory_survives_empty_snapshots_and_never_gets_arrival_freshness(self):
        self.store.local_publish("pane", snapshot([reading("closed")], observed=10))
        self.clock.advance(100)
        self.store.local_publish("pane", snapshot([], observed=11))
        view = self.complete_view()
        self.assertEqual(view["records"][0]["snapshot"]["readings"], [])
        self.assertEqual([entry["reading"]["id"] for entry in view["inventory"]], ["closed"])
        self.assertEqual(view["sources"][0]["status"], "stale")

    def test_idempotent_retry_does_not_change_received_timestamp(self):
        peer = self.peer()
        value = publication(peer.device_id)
        self.store.publish(peer, value)
        received = next(source["last_received_ms"] for source in self.complete_view()["sources"] if source["source_id"] == peer.device_id)
        self.clock.advance(100)
        self.store.publish(peer, value)
        again = next(source["last_received_ms"] for source in self.complete_view()["sources"] if source["source_id"] == peer.device_id)
        self.assertEqual(again, received)

    def test_source_capacity_failure_is_explicit_and_preserves_last_good(self):
        peer = self.peer()
        self.store.configure({"max_sources": 1})
        good = self.store.local_publish("local", snapshot(observed=15))
        error = self.assert_error("capacity", self.store.publish, peer, publication(peer.device_id))
        self.assertIn("incomplete", error.public()["error"]["message"])
        self.assertEqual(self.store.local_records(), [good])
        self.assertEqual(self.store.diagnostics()["counts"]["snapshots"], 1)

    def test_inventory_and_total_byte_limits_roll_back_sequence_and_readings(self):
        good = self.store.local_publish("pane", snapshot())
        self.store.configure({"max_inventory": 1})
        self.assert_error("capacity", self.store.local_publish, "pane", snapshot([reading(), reading("extra")]))
        self.assertEqual(self.store.local_records(), [good])
        accepted = self.store.local_publish("pane", snapshot(observed=22))
        self.assertEqual(accepted["sequence"], 2)
        self.store.configure({"max_total_bytes": 4096})
        large = reading()
        large["source_label"] = "x" * 1024
        large["provider_label"] = "y" * 1024
        self.assert_error("capacity", self.store.local_publish, "pane", snapshot([large]))
        self.assertEqual(self.store.local_records(), [accepted])

    def test_authorization_bound_pages_freeze_updates_and_expire(self):
        self.store.configure({"export_enabled": True})
        viewer, other = self.peer(), self.peer()
        for index in range(6):
            self.store.local_publish(f"pane-{index}", snapshot([reading(str(index))], observed=index))
        first = self.store.aggregate(viewer, page_bytes=1800)
        self.assertFalse(first["complete"])
        cursor = first["next_cursor"]
        self.assert_error("forbidden", self.store.aggregate, other, cursor)
        frozen = [*first["records"]]
        self.store.local_publish("new-pane", snapshot([reading("new")]))
        page = first
        while not page["complete"]:
            page = self.store.aggregate(viewer, page["next_cursor"])
            self.assertEqual(page["revision"], first["revision"])
            frozen.extend(page["records"])
        self.assertEqual(len(frozen), 6)
        self.assertNotIn("new", {item["snapshot"]["readings"][0]["id"] for item in frozen})
        self.clock.advance(121)
        self.assert_error("expired", self.store.aggregate, viewer, cursor)

    def test_revocation_invalidates_other_viewers_frozen_pages_immediately(self):
        revoked, viewer = self.peer(), self.peer()
        self.store.publish(revoked, publication(revoked.device_id, readings=[reading(str(index)) for index in range(10)]))
        first = self.store.aggregate(viewer, page_bytes=1800)
        self.assertFalse(first["complete"])
        self.store.revoke_peer(revoked.device_id)
        self.assert_error("expired", self.store.aggregate, viewer, first["next_cursor"])
        self.assert_error("unauthorized", self.store.aggregate, revoked)
        self.assertEqual(self.complete_view()["records"], [])
        self.assertEqual(self.complete_view()["inventory"], [])

    def test_maximum_publication_and_accumulated_inventory_roundtrip_over_pages(self):
        peer = self.peer()
        readings = [reading(str(index)) | {"source_label": "x" * 1000} for index in range(600)]
        value = publication(peer.device_id, readings=readings)
        remaining = MAX_BODY - len(encode(value))
        self.assertGreater(remaining, 0)
        for item in readings:
            room = 1024 - len(item["provider_label"])
            extra = min(room, remaining)
            item["provider_label"] += "p" * extra
            remaining -= extra
            if not remaining:
                break
        self.assertEqual(remaining, 0)
        self.assertEqual(len(encode(value)), MAX_BODY)
        self.store.publish(peer, value)
        view = self.complete_view(page_bytes=32768)
        self.assertEqual(view["records"], [value])
        self.assertEqual(len(view["inventory"]), 600)
        newer = value | {"sequence": 2, "snapshot": value["snapshot"] | {"readings": []}}
        self.store.publish(peer, newer)
        retained = self.complete_view(page_bytes=32768)
        self.assertEqual(len(retained["inventory"]), 600)
        self.assertEqual(retained["records"], [newer])

    def test_page_storage_capacity_does_not_return_successful_partial_coverage(self):
        self.store.local_publish("pane", snapshot([reading(str(index)) for index in range(20)]))
        self.store.configure({"max_page_storage_bytes": 1024})
        self.assert_error("capacity", self.store.aggregate, self.owner(), page_bytes=1024)
        self.assertEqual(len(self.store.local_records()), 1)
        self.assertEqual(self.store.diagnostics()["counts"]["page_sessions"], 0)

    def test_invitation_consumption_is_single_use_and_collision_does_not_consume(self):
        existing = self.peer()
        token, credential = "a" * 64, "b" * 64
        self.store.create_invitation(token, int(self.clock() * 1000) + 1000, self.owner().group_id)
        self.assert_error("conflict", self.store.consume_invitation, token, int(self.clock() * 1000), existing.device_id, credential)
        new_device = str(uuid4())
        self.store.consume_invitation(token, int(self.clock() * 1000), new_device, credential)
        self.assert_error("expired", self.store.consume_invitation, token, int(self.clock() * 1000), str(uuid4()), "c" * 64)
        self.assertEqual(len(self.store.peers()), 2)

    def test_concurrent_invite_consumers_have_exactly_one_winner(self):
        token = "d" * 64
        self.store.create_invitation(token, int(self.clock() * 1000) + 1000, self.owner().group_id)
        second = Store(self.root, clock=self.clock)
        self.addCleanup(second.close)
        def consume(store, credential):
            try:
                store.consume_invitation(token, int(self.clock() * 1000), str(uuid4()), credential)
                return "accepted"
            except ServiceError as exc:
                return exc.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(consume, store, character * 64) for store, character in ((self.store, "e"), (second, "f"))]
            outcomes = [future.result() for future in futures]
        self.assertCountEqual(outcomes, ["accepted", "expired"])
        self.assertEqual(len(self.store.peers()), 1)

    def test_source_owner_policy_and_canonical_profile_scope(self):
        observer, intruder = self.peer(), self.peer()
        policy = self.source_policy([observer])
        self.assert_error("forbidden", self.store.set_source_policy, intruder, policy)
        valid = self.foreign_publication(observer, policy)
        self.store.publish(observer, valid)
        wrong = self.foreign_publication(intruder, policy)
        self.assert_error("forbidden", self.store.publish, intruder, wrong)
        wrong = deepcopy(valid)
        wrong["sequence"] = 2
        wrong["snapshot"]["readings"][0]["canonical_id"] = "synthetic:other:account"
        self.assert_error("forbidden", self.store.publish, observer, wrong)
        self.assert_error("forbidden", self.store.publish, observer, valid | {"profile_handles": []})
        self.assertEqual(self.complete_view()["records"], [valid])

    def test_policy_rebinding_removes_old_association_data(self):
        observer = self.peer()
        policy = self.source_policy([observer])
        value = self.foreign_publication(observer, policy)
        self.store.publish(observer, value)
        changed = deepcopy(policy)
        changed["profile_generation"] += 1
        changed["profiles"]["profile-main"] = {"generation": 2, "canonical_ids": ["synthetic:tenant:new"]}
        self.store.set_source_policy(self.owner(), changed)
        self.assertEqual(self.complete_view()["records"], [])
        self.assertEqual(self.complete_view()["inventory"], [])

    def test_client_lease_is_bounded_by_one_constant_and_expires(self):
        self.assert_error("invalid_request", self.store.register_client, "source-setup", "setup")
        self.assert_error("snapshot_rejected", self.store.register_client, "window:x", "window", 91)
        registered = self.store.register_client("window:x", "window")
        self.assertEqual(registered["expires_at_ms"], int(self.clock() * 1000) + 90_000)
        self.assertEqual(registered["duration_ms"], 90_000)
        self.assertTrue(self.store.has_live_clients())
        self.clock.advance(91)
        self.assertFalse(self.store.has_live_clients())
        self.assertEqual(self.store.expire_clients(), 1)

    def test_clients_renew_expire_and_survive_store_restart(self):
        self.assertFalse(self.store.has_live_clients())
        self.store.register_client("host-main", "host", 10)
        self.clock.advance(5)
        self.store.register_client("host-main", "host", 10)
        self.store.close()
        self.store = Store(self.root, clock=self.clock)
        self.clock.advance(6)
        self.assertTrue(self.store.has_live_clients())
        self.clock.advance(5)
        self.assertFalse(self.store.has_live_clients())
        self.assertEqual(self.store.expire_clients(), 1)
        self.assertEqual(self.store.expire_clients(), 0)

    def remote_source(self, record, entries=None):
        return {"source_id": record["subject_source_id"], "generation": record["generation"], "profile_generation": record["profile_generation"],
                "status": "stale", "last_received_ms": 30, "inventory": entries or []}

    def test_remote_replacement_is_isolated_and_complete_removal_preserves_local(self):
        local = self.store.local_publish("own", snapshot(observed=11))
        hub, device = str(uuid4()), str(uuid4())
        remote = publication(device, observed=7)
        source = self.remote_source(remote)
        self.store.replace_remote(hub, "r1", [remote, local], [source, self.remote_source(local)])
        self.assertEqual(self.store.local_records(), [local])
        self.assertEqual(len(self.complete_view()["records"]), 2)
        self.assertTrue(self.store.replace_remote(hub, "r1", [remote, local], [source, self.remote_source(local)])["idempotent"])
        self.assert_error("conflict", self.store.replace_remote, hub, "r1", [], [])
        self.store.close()
        self.clock.advance(5000)
        self.store = Store(self.root, clock=self.clock)
        self.assertEqual({record["snapshot"]["as_of_ms"] for record in self.complete_view()["records"]}, {7, 11})
        self.store.replace_remote(hub, "r2", [], [])
        self.assertEqual(self.complete_view()["records"], [local])
        self.assertEqual(self.store.local_publish("own", snapshot())["sequence"], 2)

    def test_remote_bad_or_overcapacity_projection_keeps_previous_complete_model(self):
        hub = str(uuid4())
        remote = publication(str(uuid4()), observed=9)
        source = self.remote_source(remote)
        self.store.replace_remote(hub, "r1", [remote], [source])
        self.assert_error("invalid_request", self.store.replace_remote, hub, "r2", [remote], [])
        self.store.configure({"max_sources": 2})
        another = publication(str(uuid4()))
        self.assert_error("capacity", self.store.replace_remote, hub, "r3", [remote, another], [source, self.remote_source(another)])
        self.assertEqual(self.complete_view()["records"], [remote])

    def test_remote_inventory_contains_closed_accounts_not_latest_snapshot(self):
        hub, device = str(uuid4()), str(uuid4())
        remote = publication(device, readings=[])
        inventory = [{"publisher": remote["publisher"], "observer_device_id": device, "last_received_ms": 17, "reading": reading("closed")}]
        self.store.replace_remote(hub, "revision", [remote], [self.remote_source(remote, inventory)])
        self.assertEqual([entry["reading"]["id"] for entry in self.complete_view()["inventory"]], ["closed"])
        self.assertEqual(self.store.local_records(), [])

    def test_revocation_preserves_unrelated_peers_and_local_publications(self):
        removed, retained = self.peer(), self.peer()
        self.store.publish(removed, publication(removed.device_id))
        good = publication(retained.device_id)
        self.store.publish(retained, good)
        local = self.store.local_publish("local", snapshot())
        self.store.revoke_peer(removed.device_id)
        self.assertEqual({record["publisher"] for record in self.complete_view()["records"]}, {good["publisher"], local["publisher"]})
        self.assert_error("unauthorized", self.store.publish, removed, publication(removed.device_id))
        self.assertFalse(next(peer for peer in self.store.peers() if peer["device_id"] == retained.device_id)["revoked"])

    def test_projection_and_errors_never_export_private_state_or_extra_fields(self):
        marker = "CREDENTIAL-PRIVATE-TRANSCRIPT-/home/user/profile"
        value = snapshot() | {"transcript": marker, "credential": marker, "path": marker}
        value["readings"][0]["environment"] = marker
        self.store.local_publish("pane", value)
        self.store.set_local_state("helper_interpreter", marker)
        peer = self.peer()
        serialized = encode({"view": self.complete_view(peer), "diagnostics": self.store.diagnostics(), "settings": self.store.settings()})
        self.assertNotIn(marker.encode(), serialized)
        exception = self.assert_error("invalid_request", self.store.configure, {"command": marker})
        self.assertNotIn(marker, str(exception))
        self.assertNotIn("credential_hash", encode(self.store.diagnostics()).decode())
        self.assertEqual(self.store.local_state("helper_interpreter"), marker)

    def test_repair_cannot_revive_retired_epochs_or_cached_revoked_data(self):
        peer = self.peer()
        first = publication(peer.device_id, sequence=5)
        second = first | {"epoch": str(uuid4()), "sequence": 1}
        self.store.publish(peer, first)
        self.store.publish(peer, second)
        self.store.revoke_peer(peer.device_id)
        repaired = self.peer(peer.device_id)
        self.assert_error("replay", self.store.publish, repaired, first | {"sequence": 999})
        self.store.publish(repaired, second)
        self.assertEqual(self.complete_view()["records"], [])
        accepted = second | {"sequence": 2}
        self.store.publish(repaired, accepted)
        self.assertEqual(self.complete_view()["records"], [accepted])

    def test_source_removal_invalidates_remote_pages_without_touching_local_sequence(self):
        self.store.local_publish("local", snapshot())
        hub = str(uuid4())
        record = publication(str(uuid4()), readings=[reading(str(index)) for index in range(20)])
        self.store.replace_remote(hub, "one", [record], [self.remote_source(record)])
        first = self.store.aggregate(self.owner(), page_bytes=1800)
        self.assertFalse(first["complete"])
        self.store.replace_remote(hub, "two", [], [])
        self.assert_error("expired", self.store.aggregate, self.owner(), first["next_cursor"])
        self.assertEqual(self.store.local_publish("local", snapshot())["sequence"], 2)

    def test_pre_2_0_cache_is_local_display_only_and_deduplicates_history(self):
        peer = self.peer()
        cached = snapshot(observed=42) | {"publisher": "foreign-original-publisher"}
        key = "cached_snapshot:" + hashlib.sha256(cached["publisher"].encode()).hexdigest()
        self.store.set_local_state(key, cached | {"private_path": "/private/not-exported"})
        self.store.set_local_state("cached_snapshot_index", [key, key])
        self.store.set_local_state("muse_history", cached)
        local = self.store.aggregate(self.owner())
        self.assertEqual(local["cached_snapshots"], [cached])
        self.assertEqual(local["cached_chunks"], [])
        self.assertEqual(local["records"], [])
        self.assertEqual(local["inventory"], [])
        self.assertEqual(self.store.local_records(), [])
        self.assertEqual(self.store.diagnostics()["counts"]["publishers"], 0)
        self.assertEqual(self.store.diagnostics()["counts"]["known_inventory"], 0)
        remote = self.store.aggregate(peer)
        self.assertNotIn("cached_snapshots", remote)
        self.assertNotIn("cached_chunks", remote)
        self.assertNotIn(cached["publisher"].encode(), encode(remote))

    def test_large_pre_2_0_cache_is_chunked_and_frozen_without_refreshing_time(self):
        cached = snapshot([reading(str(index)) | {"source_label": "x" * 900} for index in range(300)], observed=7)
        cached["publisher"] = "foreign-cache"
        key = "cached_snapshot:" + hashlib.sha256(cached["publisher"].encode()).hexdigest()
        self.store.set_local_state(key, cached)
        self.store.set_local_state("cached_snapshot_index", [key])
        first = self.store.aggregate(self.owner(), page_bytes=16384)
        self.assertFalse(first["complete"])
        self.store.set_local_state(key, cached | {"as_of_ms": 999})
        page, chunks = first, {}
        while True:
            self.assertEqual(page["revision"], first["revision"])
            self.assertLessEqual(len(encode(page)), MAX_BODY)
            self.assertEqual(page["cached_snapshots"], [])
            for chunk in page["cached_chunks"]:
                self.assertEqual(chunk["record_id"], hashlib.sha256(encode(cached)).hexdigest())
                self.assertEqual(chunk["size"], len(encode(cached)))
                chunks[chunk["index"]] = base64.b64decode(chunk["data"], validate=True)
                count = chunk["count"]
            if page["complete"]:
                break
            page = self.store.aggregate(self.owner(), page["next_cursor"])
        self.assertEqual(set(chunks), set(range(count)))
        self.assertEqual(decode(b"".join(chunks[index] for index in range(count))), cached)
        self.assertEqual(self.store.local_records(), [])
        self.assertEqual(self.store.diagnostics()["counts"]["snapshots"], 0)

    def test_missing_pre_2_0_cache_is_explicit_without_affecting_peer_projection(self):
        peer = self.peer()
        self.store.set_local_state("cached_snapshot_index", ["cached_snapshot:" + "0" * 64])
        self.assert_error("invalid_request", self.store.aggregate, self.owner())
        self.assertTrue(self.store.aggregate(peer)["complete"])


if __name__ == "__main__":
    unittest.main()
