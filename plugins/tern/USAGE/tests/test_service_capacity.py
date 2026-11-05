"""Real Store/assembler capacity boundaries and owner account bindings; no providers or listeners."""
import asyncio
import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from usage_service.capacity import Capacity, PART_BYTES
from usage_service.display import Display
from usage_service.protocol import Authority, ServiceError, decode, encode
from usage_service.refresh import BINDINGS, Refresh
from usage_service.server import Companion
from usage_service.store import Store
from usage_service import spawn_roster

WORK = "claude:email:work%40example.test"


def binding(canonical="claude:fixture"):
    return {"handle": "fixture-handle", "generation": 1, "canonical_ids": [canonical]}


def snapshot(count=1, bound=True):
    """One SPAWN account whose readings are its evidence; `bound` carries an owner binding."""
    readings = [{"id": str(i), "provider": "claude", "provider_label": "Claude", "source_label": "水é" * 80,
                 "usage_source": "headless", "canonical_id": "claude:fixture", "windows": [
                     {"key": "five_hour", "pool": "default", "used": 20, "remaining": 80,
                      "observed_at_ms": 999000, "resets_at_ms": 1100000, "reset_observed_at_ms": 999000}]}
                for i in range(count)]
    account = {"id": "work", "provider": "claude", "provider_label": "Claude", "account_label": "Work",
               "canonical_ids": ["claude:fixture"], "reading_ids": [reading["id"] for reading in readings],
               "definition_revision": "a" * 64}
    if bound:
        account["profile_binding"] = binding()
    return {"version": 3, "publisher": "fixture", "as_of_ms": 1000000, "readings": readings,
            "roster": {"version": 1, "scopes": [{"id": "scope", "revision": "definition", "updated_at_ms": 1000000,
                                                 "accounts": [account], "consumers": []}]}}


class CapacityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.wall = 1000.0
        self.mono = 10.0
        self.root = Path(self.temp.name) / "usage" / "companion"
        self.root.mkdir(mode=0o700, parents=True)
        self.store = Store(self.root, clock=lambda: self.wall)
        self.addCleanup(self.store.close)
        source = self.store.identity()
        self.owner = Authority(source["device_id"], source["group_id"], "owner", True)
        self.capacity = Capacity(self.store, clock=lambda: self.mono)
        self.store.configure({"capacity_enabled": True})

    def request(self, op="snapshot", **fields):
        return self.capacity.request(self.owner, {"version": 1, "request_id": "test", "op": op, **fields})["response"]

    def assemble(self, first=None):
        page = first or self.request()
        first, pieces = page, []
        while True:
            self.assertTrue(page["ok"], page)
            self.assertEqual(page["index"], len(pieces))
            self.assertEqual(page["revision"], first["revision"])
            self.assertLessEqual(len(page["data"].encode()), PART_BYTES)
            pieces.append(page["data"])
            if page["complete"]:
                break
            page = self.request("page", revision=first["revision"], cursor=page["next_cursor"])
        raw = "".join(pieces).encode()
        self.assertEqual(len(raw), first["size"])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), first["revision"])
        return first, decode(raw, maximum=8 * 1024 * 1024)

    def test_export_is_off_by_default_and_needs_owner_consent(self):
        fresh = Store(Path(self.temp.name) / "other")
        self.addCleanup(fresh.close)
        self.assertFalse(fresh.settings()["capacity_enabled"])
        source = fresh.identity()
        owner = Authority(source["device_id"], source["group_id"], "owner", True)
        response = Capacity(fresh).request(owner, {"version": 1, "request_id": "x", "op": "snapshot"})["response"]
        self.assertEqual(response["status"], "export_disabled")
        companion = Companion(Path(self.temp.name) / "third", {})
        self.addCleanup(companion.store.close)
        with self.assertRaises(ServiceError) as caught:
            asyncio.run(companion.configure({"changes": {"capacity_enabled": True}}))
        self.assertEqual(caught.exception.code, "forbidden")
        asyncio.run(companion.configure({"changes": {"capacity_enabled": True}, "consent": {"capacity": True}}))
        self.assertTrue(companion.store.settings()["capacity_enabled"])

    def test_complete_bound_evidence_and_current_validation(self):
        original = snapshot()
        self.store.local_publish("host", original)
        first, document = self.assemble()
        self.assertEqual(document["records"][0]["snapshot"]["readings"], original["readings"])
        self.assertEqual(document["quota_unit"], "percent")
        self.assertEqual(document["model_mapping"], "unknown")
        self.assertEqual(first["expires_at_ms"], 1100000)
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "current")
        self.assertNotIn("cached_snapshots", document)

    def test_auth_revision_is_an_opaque_string_on_every_response(self):
        # ORCH+ validates auth_revision as a non-empty string; an integer page is rejected as malformed.
        self.store.local_publish("host", snapshot())
        first, document = self.assemble()
        validated = self.request("validate", revision=first["revision"])
        for value in (first["auth_revision"], document["auth_revision"], validated["auth_revision"]):
            self.assertIsInstance(value, str)
            self.assertTrue(value)
        self.assertEqual(first["auth_revision"], document["auth_revision"])
        self.assertEqual(first["auth_revision"], validated["auth_revision"])

    def test_export_omits_quota_of_unbound_accounts(self):
        value = snapshot()
        value["readings"].append(dict(copy.deepcopy(value["readings"][0]), id="other"))
        value["roster"]["scopes"][0]["accounts"].append({
            "id": "unbound", "provider": "claude", "provider_label": "Claude", "account_label": "Other",
            "canonical_ids": ["claude:fixture"], "reading_ids": ["other"], "definition_revision": "b" * 64})
        value["roster"]["scopes"][0]["consumers"].append({"id": "omp", "label": "OMP", "reading_ids": [],
                                                           "definition_revision": "c" * 64, "account_ids": ["unbound"]})
        self.store.local_publish("host", value)
        _, document = self.assemble()
        exported = document["records"][0]["snapshot"]
        self.assertEqual([reading["id"] for reading in exported["readings"]], ["0"])
        accounts = {account["id"]: account for account in exported["roster"]["scopes"][0]["accounts"]}
        self.assertEqual(accounts["unbound"]["reading_ids"], [])
        self.assertEqual(accounts["unbound"]["canonical_ids"], [])
        self.assertEqual(accounts["work"]["reading_ids"], ["0"])
        self.assertNotIn("account_ids", exported["roster"]["scopes"][0]["consumers"][0])
        self.store.local_publish("host", snapshot(bound=False))
        _, unbound = self.assemble()
        self.assertEqual(unbound["records"][0]["snapshot"]["readings"], [])
        self.assertEqual(unbound["inventory"], [])

    def test_frozen_pages_do_not_authorize_changed_evidence(self):
        self.store.local_publish("host", snapshot(350))
        first = self.request()
        self.assertGreater(first["count"], 1)
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "incomplete")
        changed = snapshot()
        changed["readings"][0]["windows"][0].update(used=90, remaining=10)
        self.store.local_publish("host", changed)
        _, document = self.assemble(first)
        self.assertEqual(len(document["records"][0]["snapshot"]["readings"]), 350)
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "evidence_changed")

    def test_disabled_revoked_and_reenabled_reject_old_sessions(self):
        first, _ = self.assemble()
        self.store.configure({"capacity_enabled": False})
        self.assertEqual(self.request()["status"], "export_disabled")
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "export_revoked")
        self.store.configure({"capacity_enabled": True})
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "export_revoked")

    def test_reset_and_monotonic_expiry_never_extend_original_observation(self):
        self.store.local_publish("host", snapshot())
        first, _ = self.assemble()
        self.wall = 1100.001
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "expired")
        first, _ = self.assemble()
        self.mono += 121
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "expired")

    def test_strict_read_only_ingress(self):
        for operation in ("configure", "usage_refresh", "shutdown", "binding_candidates", "pair_accept"):
            self.assertEqual(self.request(operation)["status"], "invalid_request")
        self.assertEqual(self.request(extra="ignored")["status"], "invalid_request")
        self.assertEqual(self.request("page", revision="a" * 64, cursor="not-issued")["status"], "expired")
        peer = Authority(self.owner.device_id, self.owner.group_id)
        self.assertEqual(self.capacity.request(peer, {"version": 1, "request_id": "test", "op": "snapshot"})["response"]["status"], "forbidden")

    def test_stale_sources_and_unavailable_readings_lose_their_binding(self):
        self.store.local_publish("host", snapshot())
        self.wall = 3000
        _, document = self.assemble()
        self.assertEqual(document["sources"][0]["status"], "stale")
        value = snapshot()
        value["readings"][0]["windows"][0]["last_known_reason"] = "local_login_unavailable"
        self.store.local_publish("host", value)
        _, unavailable = self.assemble()
        account = unavailable["records"][0]["snapshot"]["roster"]["scopes"][0]["accounts"][0]
        self.assertNotIn("profile_binding", account)
        self.assertEqual(unavailable["records"][0]["snapshot"]["readings"], [])

    def test_repeated_capacity_assembly_releases_only_its_store_pages(self):
        self.store.local_publish("host", snapshot(700))
        unrelated = self.store.aggregate(self.owner)
        self.assertIsNotNone(unrelated["next_cursor"])
        baseline = self.store.diagnostics()["counts"]["page_sessions"]
        first, _ = self.assemble()
        for _ in range(34):
            self.assertEqual(self.request("validate", revision=first["revision"])["status"], "current")
            self.assertTrue(self.request()["ok"])
        self.assertEqual(self.store.diagnostics()["counts"]["page_sessions"], baseline)
        self.assertEqual(self.store.aggregate(self.owner, unrelated["next_cursor"])["revision"], unrelated["revision"])
        self.assertIn("parts", Display(self.store).page(self.owner, {}))

    def test_revoked_payloads_do_not_fill_session_capacity(self):
        first, _ = self.assemble()
        for _ in range(10):
            self.store.configure({"capacity_enabled": False})
            self.assertEqual(self.request("validate", revision=first["revision"])["status"], "export_revoked")
            self.store.configure({"capacity_enabled": True})
            self.assemble()
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "export_revoked")
        self.assertEqual(len(self.capacity.sessions), 1)

    def test_paired_projection_keeps_binding_generations_and_offline_state(self):
        remote = str(uuid4())
        generation = str(uuid4())
        value = snapshot()
        value["publisher"] = remote + ":host"
        scope = value["roster"]["scopes"][0]
        scope.update(id=remote + ":host:local", updated_at_ms=999000,
                     spawn_join={"namespace": "remote-spawn", "host_key": "host:local", "config_revision": 4})
        scope["accounts"][0]["profile_binding"] = {"handle": "remote-profile", "generation": 6, "canonical_ids": ["claude:fixture"]}
        publication = {"protocol": 1, "observer_device_id": remote, "subject_source_id": remote,
                       "publisher": value["publisher"], "epoch": str(uuid4()), "sequence": 1, "kind": "passive",
                       "generation": generation, "profile_generation": 9, "snapshot": value}
        source = {"source_id": remote, "generation": generation, "profile_generation": 9,
                  "status": "offline", "last_received_ms": 1000000, "clock_skew": False}
        self.store.replace_remote(remote, "paired-one", [publication], [source])
        first, document = self.assemble()
        self.assertEqual(document["records"][0]["snapshot"]["roster"], value["roster"])
        self.assertEqual(next(s for s in document["sources"] if s["source_id"] == remote)["status"], "offline")
        changed = copy.deepcopy(source)
        changed["profile_generation"] = 10
        self.store.replace_remote(remote, "paired-two", [publication], [changed])
        self.assertEqual(self.request("validate", revision=first["revision"])["status"], "export_revoked")


class BindingTests(unittest.TestCase):
    """Owner bindings over the real Refresh, SPAWN roster file, publication and export."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "plugin-data" / "usage" / "companion"
        self.root.mkdir(mode=0o700, parents=True)
        self.store = Store(self.root)
        self.addCleanup(self.store.close)
        self.store.configure({"metadata_enabled": True, "capacity_enabled": True})
        self.refresh = Refresh(self.store, self.root)
        self.refresh.path.parent.mkdir(parents=True)
        identity = patch.object(spawn_roster, "source_identity", return_value={"source_uid": "1000", "source_user": "fixture"})
        identity.start()
        self.addCleanup(identity.stop)
        self.records = [self.record("work"), self.record("spare", account_label="Spare"),
                        self.record("agent", provider="OMP")]
        self.save()
        source = self.store.identity()
        self.owner = Authority(source["device_id"], source["group_id"], "owner", True)
        self.capacity = Capacity(self.store, configuration=lambda: self.refresh.configuration()[2])

    @staticmethod
    def record(identifier, provider="Claude", **extra):
        return {"id": identifier, "provider": provider, "account_label": "Work", "backend": "local-terminal",
                "user": "fixture", "command": "claude", "arguments": [], **extra}

    def save(self):
        self.refresh.path.write_text(json.dumps({"authority": {
            "version": 3, "namespace": "spawn-fixture", "host_key": "host:fixture", "config_revision": 7,
            "config": {"schema": 2, "hosts": {"host:fixture": {"schema": 2, "agents": self.records}}}}}))

    def publish(self, canonical=WORK, unavailable=False):
        """What the collector publishes: one headless reading per account, bindings as emitted."""
        result = self.refresh.results()
        value = {"version": 3, "publisher": "fixture", "as_of_ms": 1800000000000, "readings": [],
                 "roster": copy.deepcopy(result["roster"])}
        for scope in value["roster"]["scopes"]:
            for account in scope["accounts"]:
                window = {"key": "seven_day", "pool": "default", "used": 8, "remaining": 92, "observed_at_ms": 1800000000000}
                if unavailable:
                    window["last_known_reason"] = "local_login_unavailable"
                reading = {"id": "reading:" + account["id"], "provider": "claude", "provider_label": "Claude",
                           "source_label": account["account_label"], "usage_source": "headless",
                           "account_id": canonical, "account_label": "work@example.test",
                           "canonical_id": canonical, "principal_id": canonical, "windows": [window]}
                value["readings"].append(reading)
                account["reading_ids"], account["canonical_ids"] = [reading["id"]], [canonical]
        self.assertEqual(self.refresh.publish({"token": result["token"], "snapshot": value}), {"accepted": True})

    def accounts(self):
        return {account["id"]: account for account in self.refresh.configuration()[2]["scopes"][0]["accounts"]}

    def candidate(self, identifier="work"):
        return next(item for item in self.refresh.binding_candidates()["accounts"] if item["id"] == identifier)

    def bind(self, identifier="work"):
        item = self.candidate(identifier)
        return self.refresh.binding_action({"operation": "bind", "scope_id": item["scope_id"], "id": identifier,
                                            "definition_revision": item["definition_revision"],
                                            "canonical_id": item["canonical_id"]}, {"binding": True})

    def error(self, function, *args):
        with self.assertRaises(ServiceError) as caught:
            function(*args)
        return caught.exception.code

    def test_candidates_need_a_current_headless_reading(self):
        item = self.candidate()
        self.assertNotIn("canonical_id", item)
        self.assertFalse(item["bound"])
        self.assertEqual(self.error(self.refresh.binding_action, {
            "operation": "bind", "scope_id": item["scope_id"], "id": "work",
            "definition_revision": item["definition_revision"], "canonical_id": WORK}, {"binding": True}),
            "binding_unavailable")
        self.publish(unavailable=True)
        self.assertNotIn("canonical_id", self.candidate())
        self.publish()
        item = self.candidate()
        self.assertEqual((item["principal"], item["canonical_id"], item["canonical_ids"]),
                         ("work@example.test", WORK, [WORK]))
        self.store.configure({"metadata_enabled": False})
        self.assertEqual(self.error(self.refresh.binding_candidates), "source_metadata_disabled")

    def test_confirm_creates_binding_and_export_carries_its_quota(self):
        self.publish()
        item = self.candidate()
        action = {"operation": "bind", "scope_id": item["scope_id"], "id": "work",
                  "definition_revision": item["definition_revision"], "canonical_id": WORK}
        self.assertEqual(self.error(self.refresh.binding_action, action, {}), "forbidden")
        self.assertEqual(self.error(self.refresh.binding_action, dict(action, canonical_id="claude:other"),
                                    {"binding": True}), "binding_changed")
        self.assertEqual(self.refresh.binding_action(action, {"binding": True}), {"binding_action": "bind"})
        scope = self.refresh.configuration()[2]["scopes"][0]
        self.assertEqual(scope["spawn_join"], {"namespace": "spawn-fixture", "host_key": "host:fixture", "config_revision": 7})
        work = next(account for account in scope["accounts"] if account["id"] == "work")
        self.assertEqual(work["profile_binding"], {"handle": spawn_roster._digest(spawn_roster.binding_key(scope["id"], "work")),
                                                   "generation": 1, "canonical_ids": [WORK]})
        self.assertTrue(self.candidate()["bound"])
        self.publish()
        response = self.capacity.request(self.owner, {"version": 1, "request_id": "r", "op": "snapshot"})["response"]
        self.assertTrue(response["complete"], response)
        document = decode(response["data"].encode())
        exported = document["records"][0]["snapshot"]
        accounts = {account["id"]: account for account in exported["roster"]["scopes"][0]["accounts"]}
        self.assertEqual(accounts["work"]["profile_binding"]["canonical_ids"], [WORK])
        self.assertEqual([reading["id"] for reading in exported["readings"]], ["reading:work"])
        self.assertEqual(accounts["spare"]["reading_ids"], [])
        current = {account["id"]: account for account in document["current_roster"]["scopes"][0]["accounts"]}
        self.assertEqual(current["work"]["profile_binding"], accounts["work"]["profile_binding"])
        self.assertEqual(current["work"]["definition_revision"], accounts["work"]["definition_revision"])
        for private in ('"user"', '"command"', '"arguments"', "source_uid"):
            self.assertNotIn(private, encode(document["current_roster"]).decode())

    def test_collector_cannot_add_a_binding(self):
        self.publish()
        result = self.refresh.results()
        value = {"version": 3, "publisher": "fixture", "as_of_ms": 1800000000000, "readings": [],
                 "roster": copy.deepcopy(result["roster"])}
        value["roster"]["scopes"][0]["accounts"][0]["profile_binding"] = binding(WORK)
        self.assertEqual(self.error(self.refresh.publish, {"token": result["token"], "snapshot": value}),
                         "source_configuration_changed")

    def test_definition_change_drops_the_binding(self):
        self.publish()
        self.bind()
        self.records[0]["account_label"] = "Edited"
        self.save()
        self.assertNotIn("profile_binding", self.accounts()["work"])
        self.assertEqual(self.store.local_state(BINDINGS)["accounts"], {})
        self.records[0]["account_label"] = "Work"
        self.save()
        self.assertNotIn("profile_binding", self.accounts()["work"])

    def test_mismatched_identity_drops_the_binding(self):
        self.publish()
        self.bind()
        self.publish(canonical="claude:email:other%40example.test")
        self.assertNotIn("profile_binding", self.accounts()["work"])
        self.publish()
        self.assertNotIn("profile_binding", self.accounts()["work"])

    def test_revoke_and_rebind_take_a_new_generation(self):
        self.publish()
        self.bind()
        scope_id = self.candidate()["scope_id"]
        self.store.configure({"metadata_enabled": False})
        self.assertNotIn("profile_binding", self.accounts()["work"])
        self.assertEqual(self.refresh.binding_action({"operation": "revoke", "scope_id": scope_id, "id": "work"}, {}),
                         {"binding_action": "revoke"})
        self.store.configure({"metadata_enabled": True})
        self.assertNotIn("profile_binding", self.accounts()["work"])
        self.bind()
        self.assertEqual(self.accounts()["work"]["profile_binding"]["generation"], 2)

    def test_owner_declared_omp_association_follows_its_account(self):
        self.publish()
        scope_id = self.candidate()["scope_id"]
        agent = self.refresh.binding_candidates()["consumers"][0]
        action = {"operation": "associate", "scope_id": scope_id, "id": "agent",
                  "definition_revision": agent["definition_revision"], "account_id": "work"}
        self.assertEqual(self.error(self.refresh.binding_action, action, {"association": True}), "binding_unavailable")
        self.bind()
        self.assertEqual(self.error(self.refresh.binding_action, action, {}), "forbidden")
        self.refresh.binding_action(action, {"association": True})
        consumer = self.refresh.configuration()[2]["scopes"][0]["consumers"][0]
        self.assertEqual(consumer["account_ids"], ["work"])
        self.refresh.binding_action({"operation": "revoke", "scope_id": scope_id, "id": "work"}, {})
        self.assertEqual(self.store.local_state(BINDINGS)["consumers"], {})
        self.assertNotIn("account_ids", self.refresh.configuration()[2]["scopes"][0]["consumers"][0])

    def test_companion_configure_routes_binding_actions_only_alone(self):
        companion = Companion(self.root, {})
        companion.store.close()
        companion.store, companion.refresh = self.store, self.refresh
        self.publish()
        item = self.candidate()
        action = {"operation": "bind", "scope_id": item["scope_id"], "id": "work",
                  "definition_revision": item["definition_revision"], "canonical_id": WORK}
        with self.assertRaises(ServiceError) as caught:
            asyncio.run(companion.configure({"binding_action": action, "changes": {"paused": True}, "consent": {"binding": True}}))
        self.assertEqual(caught.exception.code, "invalid_request")
        asyncio.run(companion.configure({"binding_action": action, "consent": {"binding": True}}))
        self.assertTrue(self.candidate()["bound"])


if __name__ == "__main__":
    unittest.main()
