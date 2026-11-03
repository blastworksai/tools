import copy
import json
import unittest
from pathlib import Path

from usage_service.protocol import MAX_BODY, MAX_WINDOWS, REASONS, ServiceError, encode, integer, validate_publication, validate_snapshot

CORPUS = json.loads((Path(__file__).parent / "fixtures" / "snapshots.json").read_text())
BASE = json.loads(CORPUS[0]["raw"])


def roster():
    return {"version": 1, "scopes": [{"id": "host:fixture", "revision": "definition-1", "updated_at_ms": 1000,
            "accounts": [{"id": "configured-account", "provider": "claude", "provider_label": "Claude",
                          "account_label": "Configured account", "canonical_ids": ["claude:fixture"], "reading_ids": ["reading"]}],
            "consumers": [{"id": "omp", "label": "OMP configured", "reading_ids": ["omp-pane"]}]}]}


class ProtocolTests(unittest.TestCase):
    def test_shared_snapshot_corpus(self):
        for case in CORPUS:
            with self.subTest(case=case["name"]):
                if case["accepted"]:
                    self.assertEqual(validate_snapshot(case["raw"]), case["expected"])
                else:
                    with self.assertRaises(ServiceError) as caught:
                        validate_snapshot(case["raw"])
                    self.assertNotIn("SECRET_", str(caught.exception.public()))

    def test_roster_survives_existing_snapshot_projection(self):
        value = copy.deepcopy(BASE)
        value["roster"] = roster()
        expected = copy.deepcopy(value["roster"])
        value["roster"]["source_path"] = "SECRET_SOURCE_PATH"
        value["roster"]["scopes"][0]["source_uid"] = "SECRET_SOURCE_UID"
        value["roster"]["scopes"][0]["accounts"][0]["command"] = "SECRET_COMMAND"
        value["roster"]["scopes"][0]["consumers"][0]["environment"] = "SECRET_ENVIRONMENT"
        projected = validate_snapshot(value)
        self.assertEqual(projected["roster"], expected)
        self.assertEqual(projected["version"], 3)
        self.assertNotIn(b"SECRET_", encode(projected))
        value["roster"]["scopes"][0]["accounts"][0]["provider"] = "c" * 256
        self.assertEqual(validate_snapshot(value)["roster"]["scopes"][0]["accounts"][0]["provider"], "c" * 256)
        value["roster"] = {"version": 1, "scopes": []}
        self.assertEqual(validate_snapshot(value)["roster"], value["roster"])

    def test_invalid_roster_rejects_instead_of_becoming_empty_membership(self):
        mutations = (
            lambda r: r.update(version=2),
            lambda r: r.update(version=True),
            lambda r: r["scopes"][0].update(updated_at_ms=-1),
            lambda r: r["scopes"][0]["accounts"][0].update(canonical_ids="not-an-array"),
            lambda r: r["scopes"][0]["accounts"][0].update(reading_ids=["bad\nidentity"]),
            lambda r: r["scopes"].append(copy.deepcopy(r["scopes"][0])),
            lambda r: r["scopes"][0]["accounts"].append(copy.deepcopy(r["scopes"][0]["accounts"][0])),
            lambda r: r["scopes"][0]["consumers"][0].update(id="configured-account"),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                value = copy.deepcopy(BASE)
                value["roster"] = roster()
                mutate(value["roster"])
                with self.assertRaises(ServiceError):
                    validate_snapshot(value)

    def test_reading_and_window_capacity_boundaries(self):
        value = copy.deepcopy(BASE)
        value["readings"] *= 1000
        self.assertEqual(len(validate_snapshot(value)["readings"]), 1000)
        value["readings"].append(value["readings"][0])
        with self.assertRaises(ServiceError):
            validate_snapshot(value)
        value = copy.deepcopy(BASE)
        value["readings"][0]["windows"] *= MAX_WINDOWS
        self.assertEqual(len(validate_snapshot(value)["readings"][0]["windows"]), MAX_WINDOWS)
        value["readings"][0]["windows"].append(value["readings"][0]["windows"][0])
        with self.assertRaises(ServiceError):
            validate_snapshot(value)

    def test_unprojected_bytes_count_toward_ingress_limit(self):
        value = copy.deepcopy(BASE)
        value["untrusted"] = "x" * MAX_BODY
        with self.assertRaises(ServiceError) as caught:
            validate_snapshot(value)
        self.assertEqual(caught.exception.code, "snapshot_too_large")

    def test_huge_numbers_fail_with_safe_error(self):
        with self.assertRaises(ServiceError):
            integer(10 ** 400)
        value = copy.deepcopy(BASE)
        value["readings"][0]["windows"][0]["used"] = 10 ** 400
        with self.assertRaises(ServiceError):
            validate_snapshot(value)

    def test_authority_fields_survive_projection_and_leases_are_gone(self):
        device = "11111111-1111-4111-8111-111111111111"
        publication = {"protocol": 1, "observer_device_id": device, "subject_source_id": device,
                       "publisher": BASE["publisher"], "epoch": "22222222-2222-4222-8222-222222222222",
                       "generation": "33333333-3333-4333-8333-333333333333", "sequence": 1,
                       "profile_generation": 0, "kind": "passive", "profile_handles": ["opaque-profile"],
                       "snapshot": BASE, "credential": "SECRET_CREDENTIAL_SENTINEL"}
        projected = validate_publication(publication)
        self.assertEqual(projected["profile_handles"], ["opaque-profile"])
        self.assertNotIn(b"SECRET_", encode(projected))
        for change in ({"kind": "active"}, {"lease_id": "synthetic-lease"}, {"window_id": "synthetic-window"}):
            with self.subTest(change=change):
                with self.assertRaises(ServiceError) as caught:
                    validate_publication(publication | change)
                self.assertEqual(caught.exception.code, "invalid_request")
        publication["publisher"] = "other-publisher"
        with self.assertRaises(ServiceError) as caught:
            validate_publication(publication)
        self.assertEqual(caught.exception.code, "forbidden")

    def test_legacy_usage_source_values_are_normalized(self):
        for legacy, current in (("native-headless", "headless"), ("native-passive:last-good", "last-good"),
                                ("headless", "headless"), ("last-good", "last-good")):
            with self.subTest(legacy=legacy):
                value = copy.deepcopy(BASE)
                value["readings"][0]["usage_source"] = legacy
                self.assertEqual(validate_snapshot(value)["readings"][0]["usage_source"], current)

    def test_unhashable_reasons_are_rejected_not_crashing(self):
        for key in ("last_known_reason", "unavailable_reason"):
            with self.subTest(key=key):
                value = copy.deepcopy(BASE)
                window = value["readings"][0]["windows"][0]
                window[key] = []
                with self.assertRaises(ServiceError) as caught:
                    validate_snapshot(value)
                self.assertEqual(caught.exception.code, "snapshot_rejected")

    def test_new_reason_codes_have_messages(self):
        for code in ("source_remote", "web_login_expired"):
            self.assertIn(code, REASONS)
            self.assertEqual(ServiceError(code).code, code)


if __name__ == "__main__":
    unittest.main()
