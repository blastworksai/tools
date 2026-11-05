import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from usage_service import spawn_roster as roster
from usage_service.protocol import ServiceError


def record(identifier="claude-work", provider="Claude", user="fixture-one", **changes):
    return {"id": identifier, "provider": provider, "account_label": "Work", "user": user,
            "backend": "local-terminal", "enabled": True, "include_all": True, "duplicate_policy": "skip",
            "placement": "tab", "command": "private-command", "arguments": [], **changes}


def authority(records, host_key="host:fixture"):
    # The SPAWN 0.1.0 authority shape (SPAWN authority.luau validate/open).
    return {"version": 3, "namespace": "host-1-00000001-00000002-00000003-4", "next_authority": 2,
            "host_key": host_key, "config": {"schema": 2, "hosts": {host_key: {"schema": 2, "agents": records}}},
            "config_revision": 0, "sessions": {}, "reviewed_sources": {}}


class SpawnRosterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "kv.json"
        self.users = {"fixture-one": "2001", "fixture-two": "2002"}
        self.uid = patch.object(roster, "_uid", side_effect=lambda user: self.users.get(user))
        self.uid.start()
        self.addCleanup(self.uid.stop)
        self.identity = patch.object(roster, "source_identity",
                                     return_value={"source_uid": "2001", "source_user": "fixture-one"})
        self.identity.start()
        self.addCleanup(self.identity.stop)

    def write(self, value, at=2000000000000):
        self.path.write_text(json.dumps(value))
        os.utime(self.path, ns=(at * 1000000, at * 1000000))

    def save(self, records, host_key="host:fixture", at=2000000000000):
        self.write({"authority": authority(records, host_key)}, at)

    def read(self, installation="installation-one"):
        return roster.read_roster(self.path, installation)

    def scope(self, installation="installation-one"):
        result, _ = self.read(installation)
        self.assertEqual(len(result["scopes"]), 1)
        return result["scopes"][0]

    def assert_invalid(self):
        with self.assertRaises(ServiceError) as caught:
            self.read()
        self.assertEqual(caught.exception.code, "source_roster_invalid")

    def test_live_definitions_update_remove_and_keep_file_time(self):
        self.save([record()])
        result, local = self.read()
        first = result["scopes"][0]
        self.assertEqual(first["updated_at_ms"], 2000000000000)
        self.assertEqual(first["accounts"], [{"id": "claude-work", "provider": "claude", "provider_label": "Claude",
                                              "account_label": "Work", "canonical_ids": [], "reading_ids": [],
                                              "definition_revision": local[0]["revision"]}])
        self.save([record(account_label="Renamed"), record("unmeasured", "Muse", "fixture-two", enabled=False)],
                  at=2000000001000)
        second = self.scope()
        self.assertNotEqual(first["revision"], second["revision"])
        self.assertEqual(second["updated_at_ms"], 2000000001000)
        self.assertEqual([entry["id"] for entry in second["accounts"]], ["claude-work", "unmeasured"])
        self.save([])
        self.assertEqual(self.scope()["accounts"], [])
        self.path.unlink()
        self.assertEqual(self.read(), ({"version": 1, "scopes": []}, []))

    def test_missing_authority_means_no_configured_accounts(self):
        for value in ({}, {"migration-original": {"schema": 1, "agents": [record()]}},
                      {"config": {"schema": 2, "hosts": {"host:fixture": {"schema": 2, "agents": [record()]}}}}):
            with self.subTest(value=value):
                self.write(value)
                self.assertEqual(self.read(), ({"version": 1, "scopes": []}, []))

    def test_stale_top_level_config_never_overrides_the_authority_roster(self):
        # SPAWN keeps its pre-migration original in `config`; the live roster is `authority`.
        stale = {"schema": 2, "hosts": {"host:fixture": {"schema": 2, "agents": [
            record("stale-account", "Codex"), record()]}}}
        self.write({"config": stale, "authority": authority([record(account_label="Current"),
                                                             record("new-account", "Muse")])})
        result, definitions = self.read()
        scope = result["scopes"][0]
        self.assertEqual([(entry["id"], entry["account_label"]) for entry in scope["accounts"]],
                         [("claude-work", "Current"), ("new-account", "Work")])
        self.assertEqual([item["id"] for item in definitions], ["claude-work", "new-account"])

    def test_only_this_execution_hosts_bucket_is_read(self):
        value = authority([record()], "host:this")
        value["config"]["hosts"]["host:other"] = {"schema": 1, "agents": [record("other-device", "Codex")]}
        self.write({"authority": value})
        scope = self.scope()
        self.assertEqual(scope["id"], "host:this")
        self.assertEqual([entry["id"] for entry in scope["accounts"]], ["claude-work"])

    def test_local_scope_ids_keep_separate_installations_distinct(self):
        self.save([record()], host_key="host:local")
        self.assertEqual(self.scope()["id"], "installation-one:host:local")
        self.assertNotEqual(self.scope()["id"], self.scope("installation-two")["id"])
        self.save([record()], host_key="host:remote")
        self.assertEqual(self.scope()["id"], "host:remote")
        self.assertEqual(self.scope("installation-two")["id"], "host:remote")

    def test_invalid_and_unreadable_never_become_successful_empty_registry(self):
        def mutate(change):
            value = authority([record()])
            change(value)
            return {"authority": value}
        for value in ([], {"authority": None}, {"authority": []}, {"authority": "corrupt"},
                      mutate(lambda v: v.update(version=2)), mutate(lambda v: v.update(version="3")),
                      mutate(lambda v: v.update(version=3.0)), mutate(lambda v: v.pop("host_key")),
                      mutate(lambda v: v.update(host_key="")), mutate(lambda v: v.update(host_key=7)),
                      mutate(lambda v: v.update(config=None)), mutate(lambda v: v["config"].update(schema=1)),
                      mutate(lambda v: v["config"].update(schema=True)), mutate(lambda v: v["config"].update(hosts=[])),
                      mutate(lambda v: v.update(host_key="host:missing")),
                      mutate(lambda v: v["config"]["hosts"]["host:fixture"].update(schema=1)),
                      mutate(lambda v: v["config"]["hosts"]["host:fixture"].update(agents=None)),
                      mutate(lambda v: v["config"]["hosts"].update({"host:fixture": []})),
                      {"authority": authority([{}])}, {"authority": authority(["record"])},
                      {"authority": authority([record(), record()])},
                      {"authority": authority([record(id=None)])}):
            with self.subTest(value=value):
                self.write(value)
                self.assert_invalid()
        self.path.write_text("{")
        with self.assertRaises(ServiceError) as caught:
            self.read()
        self.assertEqual(caught.exception.code, "source_roster_unavailable")
        self.save([record()])
        with patch.object(Path, "open", side_effect=PermissionError()), self.assertRaises(ServiceError) as caught:
            self.read()
        self.assertEqual(caught.exception.code, "source_roster_unavailable")

    def test_text_follows_the_luau_roster_rule(self):
        self.save([record(account_label="x" * 1024)])
        self.assertEqual(self.scope()["accounts"][0]["account_label"], "x" * 1024)
        self.save([record(account_label="é" * 512)])
        self.assertEqual(len(self.scope()["accounts"]), 1)
        for change in ({"account_label": "x" * 1025}, {"account_label": "é" * 513},
                       {"account_label": "Work\x7f"}, {"account_label": "Work\x1b[0m"},
                       {"account_label": "   "}, {"provider": "Tab\tProvider"}, {"id": "line\nbreak"},
                       {"provider": "p" * 257}):
            with self.subTest(change=change):
                self.save([record(**change)])
                self.assert_invalid()
        # An OMP consumer label joins provider and account labels.
        self.save([record("consumer", "OMP", account_label="x" * 1020)])
        self.assert_invalid()
        self.save([record()], host_key="host:" + "h" * 600)
        self.assert_invalid()

    def test_more_than_128_definitions_is_invalid_not_truncated(self):
        self.save([record("account-" + str(index)) for index in range(128)])
        self.assertEqual(len(self.scope()["accounts"]), 128)
        self.save([record("account-" + str(index)) for index in range(129)])
        self.assert_invalid()

    def test_local_definitions_resolve_only_local_execution_users(self):
        default = record("default")
        del default["user"]
        self.save([default, record("named", user="fixture-two"), record("unknown", user="nobody-here"),
                   record("current-name", user="fixture-one"),
                   record("remote", backend="ssh-command", host="gpu.example.invalid", user="fixture-two"),
                   record("remote-default", backend="ssh-command", host="gpu.example.invalid", user="")])
        _, definitions = self.read()
        self.assertEqual({item["id"]: item["source_uid"] for item in definitions},
                         {"default": "2001", "named": "2002", "unknown": None, "current-name": "2001",
                          "remote": None, "remote-default": None})
        with patch.object(roster, "source_identity", side_effect=roster.SafeError("unavailable")):
            self.save([default])
            self.assertIsNone(self.read()[1][0]["source_uid"])

    def test_launch_options_and_key_order_do_not_change_revision(self):
        definitions = [record(arguments={}), record("consumer", "OMP", "fixture-two", arguments={})]
        self.save(definitions)
        original = self.scope()
        copied = []
        for item in reversed(definitions):
            item = {**item, "enabled": False, "include_all": False, "duplicate_policy": "allow",
                    "placement": "split", "review_required": True, "review_reason": "Review",
                    "prompt": "Different launch prompt", "arguments": []}
            copied.append(dict(reversed(list(item.items()))))
        self.save(copied, at=2000000001000)
        saved, mtime = self.path.read_bytes(), self.path.stat().st_mtime_ns
        actual = self.scope("copied-device")
        self.assertEqual(actual["id"], original["id"])
        self.assertEqual(actual["revision"], original["revision"])
        self.assertEqual(actual["accounts"], original["accounts"])
        self.assertEqual(actual["consumers"], original["consumers"])
        self.assertEqual(self.path.read_bytes(), saved)
        self.assertEqual(self.path.stat().st_mtime_ns, mtime)

    def test_account_selectors_and_membership_changes_are_not_normalized_away(self):
        base = record(arguments=["--profile", "work"])
        self.save([base])
        original = self.scope()
        _, definitions = self.read()
        for change in (
                {"command": "different-command"},
                {"arguments": ["--profile", "personal"]},
                {"arguments": ["work", "--profile"]},
                {"arguments": ["--profile", "work", ""]},
                {"user": "fixture-two"},
                {"cwd": "/profile/personal"},
                {"host": "foreign.invalid"},
                {"key_path": "/profile/ssh-key"},
                {"backend": "ssh-command"},
                {"account_label": "Personal"},
                {"provider": "Muse"},
                {"id": "different-account"}):
            with self.subTest(change=change):
                self.save([{**base, **change}])
                changed = self.scope()
                self.assertNotEqual(changed["revision"], original["revision"])
                self.assertNotEqual(self.read()[1][0]["revision"], definitions[0]["revision"])
                self.assertEqual([entry["id"] for entry in changed["accounts"]], [change.get("id", "claude-work")])
        self.save([base, record("new", "Muse", "fixture-two")])
        added = self.scope()
        self.assertNotEqual(added["revision"], original["revision"])
        self.assertEqual([item["id"] for item in added["accounts"]], ["claude-work", "new"])

    def test_malformed_argument_collections_do_not_become_empty_definitions(self):
        for arguments in ("--profile work", {"profile": "work"}, [False], ["nul\0argument"]):
            with self.subTest(arguments=arguments):
                self.save([record(arguments=arguments)])
                self.assert_invalid()

    def test_omp_consumers_never_supply_accounts_or_wire_selectors(self):
        omp = record("consumer", "OMP", "fixture-two", include_all=False)
        self.save([record(), omp, record("custom", "Custom Provider", "missing", enabled=False)])
        result, definitions = self.read()
        scope = result["scopes"][0]
        self.assertEqual(len(scope["accounts"]), 2)
        self.assertEqual(scope["consumers"], [{"id": "consumer", "label": "OMP · Work", "reading_ids": [],
                                               "definition_revision": roster._digest(roster._definition(omp, "Work"))}])
        self.assertEqual(scope["accounts"][1]["provider"], "custom provider")
        self.assertEqual([item["id"] for item in definitions], ["claude-work", "custom"])
        encoded = json.dumps(result)
        for private in ("fixture-one", "fixture-two", "private-command", "source_uid", '"user"'):
            self.assertNotIn(private, encoded)

    def test_thirteen_record_shape_keeps_complete_membership(self):
        providers = ["Claude", "Claude", "Codex", "Codex", "Kimi", "Muse", "Agy", "Agy", "Agy", "Agy", "Grok", "OMP", "OMP"]
        self.save([record("entry-" + str(index), name) for index, name in enumerate(providers)])
        result, definitions = self.read()
        scope = result["scopes"][0]
        self.assertEqual(len(scope["accounts"]), 11)
        self.assertEqual(len(scope["consumers"]), 2)
        self.assertEqual(len(definitions), 11)
        self.assertTrue(all(not item["canonical_ids"] and not item["reading_ids"] for item in scope["accounts"]))

    def test_spawn_join_and_bindings_follow_the_current_definition(self):
        self.save([record(), record("remote", backend="ssh-command"), record("consumer", "OMP")])
        result, local = self.read()
        scope = result["scopes"][0]
        self.assertEqual(scope["spawn_join"], {"namespace": "host-1-00000001-00000002-00000003-4",
                                               "host_key": "host:fixture", "config_revision": 0})
        self.assertNotIn("profile_binding", scope["accounts"][0])
        revisions = {item["id"]: item["revision"] for item in local}
        consumer_revision = scope["consumers"][0]["definition_revision"]
        key = roster.binding_key(scope["id"], "claude-work")
        bindings = {"accounts": {
            key: {"definition_revision": revisions["claude-work"], "canonical_ids": ["claude:b", "claude:a"], "generation": 4},
            roster.binding_key(scope["id"], "remote"): {"definition_revision": revisions["remote"],
                                                        "canonical_ids": ["claude:a"], "generation": 5}},
            "consumers": {roster.binding_key(scope["id"], "consumer"): {
                "definition_revision": consumer_revision, "account_id": "claude-work"}}}
        bound = roster.read_roster(self.path, "installation-one", bindings)[0]["scopes"][0]
        accounts = {entry["id"]: entry for entry in bound["accounts"]}
        self.assertEqual(accounts["claude-work"]["profile_binding"],
                         {"handle": roster._digest(key), "generation": 4, "canonical_ids": ["claude:a", "claude:b"]})
        # An SSH record is read on another machine; it is never bound here.
        self.assertNotIn("profile_binding", accounts["remote"])
        self.assertEqual(bound["consumers"][0]["account_ids"], ["claude-work"])
        self.save([record(account_label="Edited"), record("remote", backend="ssh-command"), record("consumer", "OMP")])
        edited = roster.read_roster(self.path, "installation-one", bindings)[0]["scopes"][0]
        self.assertNotIn("profile_binding", edited["accounts"][0])
        # The association stands only while its account's binding does.
        self.assertNotIn("account_ids", edited["consumers"][0])
        without_join = authority([record()])
        del without_join["config_revision"]
        self.write({"authority": without_join})
        self.assertNotIn("spawn_join", self.scope())


if __name__ == "__main__":
    unittest.main()
