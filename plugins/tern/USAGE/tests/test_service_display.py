"""Whole-revision display behavior, including bounded UTF-8 and revoked cursors."""
import base64
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from usage_service.display import Display, PAGE_BYTES, PART_BYTES
from usage_service.protocol import Authority, ServiceError, decode, encode
from usage_service.store import Store


def snapshot(count=1, label="Synthetic"):
    return {"version":3,"publisher":"fixture","as_of_ms":1234,"readings":[
        {"id":f"agent-{index}","provider":"openai","provider_label":"OpenAI","source_label":label,
         "usage_source":"fixture","windows":[{"key":"session","pool":"all","used":75,"remaining":25,"observed_at_ms":1200}]}
        for index in range(count)]}


def configured_roster():
    return {"version": 1, "scopes": [{"id": "host:fixture", "revision": "defined", "updated_at_ms": 1000,
            "accounts": [{"id": "account", "provider": "openai", "provider_label": "Codex",
                          "account_label": "Configured account", "canonical_ids": [], "reading_ids": ["agent-0"]}],
            "consumers": [{"id": "omp", "label": "OMP", "reading_ids": []}]}]}


class DisplayTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.store=Store(Path(self.temp.name)/"private")
        identity=self.store.identity()
        self.owner=Authority(identity["device_id"],identity["group_id"],"owner",True)
        self.now=100.0
        self.display=Display(self.store,clock=lambda:self.now)
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.store.close)

    def assemble(self,first=None):
        page=first or self.display.page(self.owner,{})
        revision=page["revision"]
        pieces={}
        while True:
            self.assertEqual(page["revision"],revision)
            self.assertLessEqual(len(encode({"ok":True,**page})),PAGE_BYTES)
            for part in page["parts"]:
                self.assertLessEqual(len(part["data"].encode()),PART_BYTES)
                parts=pieces.setdefault(part["publisher"],[])
                self.assertEqual(part["index"],len(parts))
                parts.append(part)
            if page["complete"]:
                break
            page=self.display.page(self.owner,{"cursor":page["next_cursor"]})
        snapshots=[]
        for publisher,parts in pieces.items():
            self.assertEqual(len(parts),parts[0]["count"])
            raw="".join(part["data"] for part in parts)
            self.assertEqual(len(raw.encode()),parts[0]["size"])
            value=decode(raw)
            self.assertEqual(value["publisher"],publisher)
            snapshots.append(value)
        return snapshots

    def large(self):
        value=snapshot(700,"é水"*90)
        self.store.local_publish("host",value)
        return value

    def test_frozen_multibyte_revision_survives_intervening_publication(self):
        original=self.large()
        first=self.display.page(self.owner,{})
        self.assertFalse(first["complete"])
        changed=snapshot();changed["readings"][0]["windows"][0].update(used=1,remaining=99)
        self.store.local_publish("host",changed)
        result=self.assemble(first)
        self.assertEqual(len(result),1)
        self.assertEqual(result[0]["readings"],original["readings"])
        self.assertEqual(result[0]["as_of_ms"],1234)
        current=self.assemble()
        self.assertEqual(sum(len(s["readings"]) for s in current),700)
        retained=next(s for s in current if s["publisher"].startswith("usage-inventory:"))
        self.assertEqual(retained["as_of_ms"],0)
        self.assertTrue(all(w["observed_at_ms"]==1200 for r in retained["readings"] for w in r["windows"]))
    def test_roster_and_removal_survive_existing_store_chunks_and_display_parts(self):
        value = snapshot(700, "é水" * 90)
        value["roster"] = configured_roster()
        self.store.local_publish("host", value)
        first = self.display.page(self.owner, {})
        self.assertFalse(first["complete"])
        current = self.assemble(first)
        self.assertEqual(current[0]["roster"], value["roster"])
        self.assertEqual(current[0]["readings"], value["readings"])
        removed = snapshot(0)
        removed["roster"] = configured_roster()
        removed["roster"]["scopes"][0].update(revision="removed", updated_at_ms=2000, accounts=[])
        self.store.local_publish("host", removed)
        current = self.assemble()
        live = next(s for s in current if not s["publisher"].startswith("usage-inventory:"))
        retained = next(s for s in current if s["publisher"].startswith("usage-inventory:"))
        self.assertEqual(live["roster"], removed["roster"])
        self.assertNotIn("roster", retained)
        self.assertEqual(len(retained["readings"]), 700)


    def test_muse_unavailable_refresh_and_reopen_keep_exact_measured_windows(self):
        value = snapshot()
        reading = value["readings"][0]
        reading.update(provider="muse", provider_label="Muse", canonical_id="muse:fixture")
        reading["windows"].append({"key": "weekly", "pool": "all", "used": 15, "remaining": 85, "observed_at_ms": 1100})
        measured = [dict(window) for window in reading["windows"]]
        self.store.local_publish("host", value)
        reading["windows"] = [{"key": "subscription", "pool": "all", "observed_at_ms": 2000, "unavailable_reason": "unavailable"}]
        self.store.local_publish("host", value)
        reopened = Store(Path(self.temp.name) / "private")
        self.addCleanup(reopened.close)
        self.display = Display(reopened, clock=lambda: self.now)
        current = self.assemble()
        live = next(item for item in current if not item["publisher"].startswith("usage-inventory:"))
        retained = next(item for item in current if item["publisher"].startswith("usage-inventory:"))["readings"][0]
        self.assertEqual(live["readings"][0]["windows"], reading["windows"])
        self.assertEqual(retained["windows"], measured)
        self.assertEqual(retained["usage_source"], "last-good")

    def test_direct_muse_retention_keeps_current_source_bindings_and_raw_publication(self):
        value = snapshot()
        value["roster"] = configured_roster()
        account = value["roster"]["scopes"][0]["accounts"][0]
        account.update(provider="muse", provider_label="Muse")
        reading = value["readings"][0]
        reading.update(provider="muse", provider_label="Muse")
        reading["windows"][0].update(used=40, remaining=60, resets_at_ms=9000)
        measured = [dict(window) for window in reading["windows"]]
        self.store.local_publish("host", value)
        # An unrelated publication can reuse a raw ID, but cannot borrow this
        # publisher's roster bindings in its retained display snapshot.
        unrelated = snapshot()
        unrelated["readings"][0].update(provider="muse", provider_label="Muse")
        self.store.local_publish("unrelated", unrelated)
        reading["windows"] = [{"key": "session", "pool": "all", "observed_at_ms": 2000,
                               "unavailable_reason": "not_yet_measured"}]
        self.store.local_publish("host", value)
        reopened = Store(Path(self.temp.name) / "private")
        self.addCleanup(reopened.close)
        self.display = Display(reopened, clock=lambda: self.now)

        def retained_bound():
            current = self.assemble()
            retained = [item for item in current if item["publisher"].startswith("usage-inventory:")]
            bound = [item for item in retained if "roster" in item]
            self.assertEqual(len(bound), 1)
            self.assertEqual(bound[0]["roster"], value["roster"])
            self.assertEqual(bound[0]["as_of_ms"], 0)
            self.assertEqual(len(bound[0]["readings"]), 1)
            self.assertEqual(bound[0]["readings"][0]["id"], reading["id"])
            self.assertNotIn("canonical_id", bound[0]["readings"][0])
            self.assertNotIn("account_id", bound[0]["readings"][0])
            return bound[0]["readings"][0]

        self.assertEqual(retained_bound()["windows"], measured)
        raw = reopened.aggregate(self.owner, None, PAGE_BYTES)
        publication = next(record["snapshot"] for record in raw["records"]
                           if record["publisher"] == self.owner.device_id + ":host")
        self.assertEqual(publication["readings"], value["readings"])
        self.assertEqual(publication["roster"], value["roster"])
        for used, observed in ((0, 3000), (65, 4000)):
            reading["windows"] = [{"key": "session", "pool": "all", "used": used,
                                   "remaining": 100 - used, "observed_at_ms": observed,
                                   "resets_at_ms": 9000}]
            self.store.local_publish("host", value)
            expected = [dict(window) for window in reading["windows"]]
            self.assertEqual(retained_bound()["windows"], expected)
            reading["windows"] = [{"key": "session", "pool": "all", "observed_at_ms": observed + 100,
                                   "unavailable_reason": "not_yet_measured"}]
            self.store.local_publish("host", value)
            self.assertEqual(retained_bound()["windows"], expected)
        removed = value["roster"]["scopes"][0]
        removed.update(accounts=[], revision="removed", updated_at_ms=5000)
        self.store.local_publish("host", value)
        self.assertEqual(retained_bound()["windows"], expected)
        del value["roster"]
        self.store.local_publish("host", value)
        current = self.assemble()
        self.assertTrue(any(item["publisher"].startswith("usage-inventory:") for item in current))
        self.assertTrue(all("roster" not in item for item in current))

    def test_muse_retention_uses_observation_time_and_never_crosses_identity_or_omp(self):
        value = snapshot()
        reading = value["readings"][0]
        reading.update(provider="muse", provider_label="Muse", canonical_id="muse:first")
        self.store.local_publish("host", value)
        reading["windows"][0].update(used=20, remaining=80, observed_at_ms=1000)
        self.store.local_publish("host", value)
        retained = next(item for item in self.assemble() if item["publisher"].startswith("usage-inventory:"))
        self.assertEqual(retained["readings"][0]["windows"][0]["used"], 75)
        reading["canonical_id"] = "muse:second"
        reading["windows"] = [{"key": "session", "pool": "all", "observed_at_ms": 2000, "unavailable_reason": "unavailable"}]
        self.store.local_publish("host", value)
        self.assertEqual([item["publisher"] for item in self.assemble()], [self.owner.device_id + ":host"])
        reading.update(agent_id="omp", canonical_id="muse:first")
        reading["windows"] = [{"key": "session", "pool": "all", "used": 90, "remaining": 10, "observed_at_ms": 3000}]
        self.store.local_publish("host", value)
        reading["windows"] = [{"key": "session", "pool": "all", "observed_at_ms": 4000, "unavailable_reason": "unavailable"}]
        self.store.local_publish("host", value)
        self.assertEqual([item["publisher"] for item in self.assemble()], [self.owner.device_id + ":host"])

    def test_remote_muse_inventory_survives_current_unavailable_and_not_withdrawal(self):
        source = Store(Path(self.temp.name) / "remote-source")
        self.addCleanup(source.close)
        value = snapshot()
        reading = value["readings"][0]
        reading.update(provider="muse", provider_label="Muse", canonical_id="muse:remote")
        measured = dict(reading, windows=[dict(window) for window in reading["windows"]])
        reading["windows"] = [{"key": "subscription", "pool": "all", "observed_at_ms": 2000, "unavailable_reason": "unavailable"}]
        publication = source.local_publish("host", value)
        source_id = publication["subject_source_id"]
        state = {"source_id": source_id, "generation": publication["generation"], "profile_generation": 0,
                 "status": "current", "clock_skew": False, "last_received_ms": 2000,
                 "inventory": [{"publisher": publication["publisher"], "observer_device_id": source_id,
                                "last_received_ms": 2000, "reading": measured}]}
        hub = str(uuid4())
        self.store.replace_remote(hub, "measured", [publication], [state])
        retained = next(item for item in self.assemble() if item["publisher"].startswith("usage-inventory:"))
        self.assertEqual(retained["readings"][0]["windows"], measured["windows"])
        self.store.replace_remote(hub, "withdrawn", [], [])
        self.assertEqual(self.assemble(), [])

    def test_imported_cache_chunk_digest_checked_before_any_display(self):
        cached=snapshot(700,"cache"*100)
        cached["roster"] = configured_roster()
        key="cached_snapshot:"+hashlib.sha256(encode(cached)).hexdigest()
        self.store.set_local_state(key,cached)
        self.store.set_local_state("cached_snapshot_index",[key])
        real=self.store.aggregate
        def damaged(*args,**kwargs):
            page=real(*args,**kwargs)
            if page["cached_chunks"]:
                chunk=page["cached_chunks"][0]
                raw=bytearray(base64.b64decode(chunk["data"]))
                raw[-1]^=1
                chunk["data"]=base64.b64encode(raw).decode()
            return page
        with patch.object(self.store,"aggregate",side_effect=damaged):
            with self.assertRaises(ServiceError) as error:
                self.display.page(self.owner,{})
            self.assertEqual(error.exception.code,"conflict")
        values=self.assemble()
        self.assertEqual(values[0]["readings"],cached["readings"])
        self.assertEqual(values[0]["as_of_ms"],1234)
        self.assertEqual(values[0]["roster"], cached["roster"])
        self.assertTrue(values[0]["publisher"].startswith("usage-cached:"))

    def test_rows_written_by_pre_2_0_builds_render_with_current_usage_source_values(self):
        live = snapshot()
        live["readings"][0]["usage_source"] = "headless"
        self.store.local_publish("host", live)
        with self.store.transaction() as db:
            # Simulate payloads persisted before the usage_source rename.
            for table in ("snapshots", "known_inventory"):
                for rowid, payload in db.execute(f"SELECT rowid,payload FROM {table}").fetchall():
                    legacy = bytes(payload).replace(b'"usage_source":"headless"', b'"usage_source":"native-headless"')
                    db.execute(f"UPDATE {table} SET payload=? WHERE rowid=?", (legacy, rowid))
        cached = snapshot(label="Imported")
        cached["readings"][0].update(id="imported", usage_source="native-passive:last-good")
        key = "cached_snapshot:" + hashlib.sha256(encode(cached)).hexdigest()
        self.store.set_local_state(key, cached)
        self.store.set_local_state("cached_snapshot_index", [key])
        sources = {reading["id"]: reading["usage_source"] for value in self.assemble() for reading in value["readings"]}
        self.assertEqual(sources, {"agent-0": "headless", "imported": "last-good"})

    def test_stored_pre_2_0_active_record_is_skipped_not_fatal(self):
        self.store.local_publish("window", snapshot(label="Delegated"))
        kept = self.store.local_publish("host", snapshot())
        with self.store.transaction() as db:
            [(payload,)] = db.execute("SELECT payload FROM snapshots WHERE publisher LIKE '%:window'").fetchall()
            active = dict(decode(payload), kind="active", lease_id="lease", window_id="window")
            db.execute("UPDATE snapshots SET payload=? WHERE publisher LIKE '%:window'", (encode(active),))
        live = [value["publisher"] for value in self.assemble() if not value["publisher"].startswith("usage-inventory:")]
        self.assertEqual(live, [kept["publisher"]])
        self.assertNotIn(active, self.store.aggregate(self.owner)["records"])

    def test_live_chunk_corruption_never_returns_partial_snapshot(self):
        self.large()
        real=self.store.aggregate
        def damaged(*args,**kwargs):
            page=real(*args,**kwargs)
            if page["record_chunks"]:
                page["record_chunks"][0]["record_id"]="f"*64
            return page
        with patch.object(self.store,"aggregate",side_effect=damaged):
            with self.assertRaises(ServiceError):
                self.display.page(self.owner,{})
        self.assertEqual(self.display.sessions,{})

    def test_authority_change_expiry_and_capacity_are_explicit(self):
        self.large()
        first=self.display.page(self.owner,{})
        policy=self.store.source_policy();policy["generation"]=str(uuid4())
        self.store.set_source_policy(self.owner,policy)
        with self.assertRaises(ServiceError) as error:
            self.display.page(self.owner,{"cursor":first["next_cursor"]})
        self.assertEqual(error.exception.code,"expired")
        second=self.display.page(self.owner,{})
        self.now+=121
        with self.assertRaises(ServiceError):
            self.display.page(self.owner,{"cursor":second["next_cursor"]})
        limits=dict(self.store.settings(),max_page_sessions=1)
        with patch.object(self.store,"settings",return_value=limits):
            self.display.page(self.owner,{})
            with self.assertRaises(ServiceError) as error:
                self.display.page(self.owner,{})
            self.assertEqual(error.exception.code,"capacity")
        with self.assertRaises(ServiceError):
            self.display.page(Authority(self.owner.device_id,self.owner.group_id),{})

    def test_remote_generation_change_invalidates_frozen_display(self):
        self.large()
        hub,source=str(uuid4()),str(uuid4())
        state={"source_id":source,"generation":str(uuid4()),"profile_generation":0,
               "status":"stale","clock_skew":False,"last_received_ms":1000,"inventory":[]}
        self.store.replace_remote(hub,"first",[],[state])
        first=self.display.page(self.owner,{})
        state["profile_generation"]=1
        self.store.replace_remote(hub,"second",[],[state])
        with self.assertRaises(ServiceError):
            self.display.page(self.owner,{"cursor":first["next_cursor"]})



if __name__=="__main__":
    unittest.main()
