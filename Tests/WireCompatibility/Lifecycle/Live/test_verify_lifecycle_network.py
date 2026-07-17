#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Host-side contracts for the network-failure lifecycle verifier."""

import base64
import importlib.util
import json
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "verify_lifecycle_network", HERE / "verify-lifecycle-network.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


def adv_record(object_type, name, route="object"):
    topic = (
        f"coaty/3/ns/ADV::{object_type}/1111"
        if route == "object"
        else "coaty/3/ns/ADV:CoatyObject/1111"
    )
    payload = {"object": {"objectType": object_type, "name": name}}
    return {
        "mqtt": {"topic": topic},
        "payload": {
            "encoding": "base64",
            "bytes": base64.b64encode(json.dumps(payload).encode()).decode(),
        },
    }


def app_log(states):
    return [{"state": state, "at": "2026-01-01T00:00:00Z"} for state in states]


QUEUE_TYPE = "com.coaty.test.WireQueuedFixture"
PROBE_TYPE = "com.coaty.test.WireFixture"
QUEUE_STATES = ["ready", "offline", "published-offline", "reconnected", "done"]
PROBE_STATES = ["ready", "offline", "reconnected", "probe-received", "done"]


class OfflineQueueingContractTests(unittest.TestCase):
    def test_accepts_ordered_exactly_once_delivery(self):
        capture = [adv_record(QUEUE_TYPE, "first"), adv_record(QUEUE_TYPE, "second")]
        VERIFY.verify_offline_queueing(capture, app_log(QUEUE_STATES))

    def test_rejects_missing_reordered_or_duplicated_publications(self):
        for names in ([], ["first"], ["second", "first"], ["first", "first", "second"]):
            capture = [adv_record(QUEUE_TYPE, name) for name in names]
            with self.assertRaises(SystemExit):
                VERIFY.verify_offline_queueing(capture, app_log(QUEUE_STATES))

    def test_ignores_the_core_type_route_instead_of_double_counting(self):
        capture = [
            adv_record(QUEUE_TYPE, "first", route="core"),
            adv_record(QUEUE_TYPE, "first"),
            adv_record(QUEUE_TYPE, "second", route="core"),
            adv_record(QUEUE_TYPE, "second"),
        ]
        VERIFY.verify_offline_queueing(capture, app_log(QUEUE_STATES))

    def test_rejects_wrong_state_sequence(self):
        capture = [adv_record(QUEUE_TYPE, "first"), adv_record(QUEUE_TYPE, "second")]
        with self.assertRaises(SystemExit):
            VERIFY.verify_offline_queueing(capture, app_log(["ready", "done"]))


class ProbeScenarioContractTests(unittest.TestCase):
    def make_app_log(self):
        log = app_log(PROBE_STATES)
        log[3]["name"] = "wire-fixture"
        return log

    def test_accepts_decoded_probe_after_reconnect(self):
        capture = [adv_record(PROBE_TYPE, "wire-fixture")]
        VERIFY.verify_reconnect_resubscribe(capture, self.make_app_log())
        VERIFY.verify_broker_restart(capture, self.make_app_log())

    def test_rejects_a_probe_missing_from_the_wire(self):
        with self.assertRaises(SystemExit):
            VERIFY.verify_reconnect_resubscribe([], self.make_app_log())

    def test_rejects_an_undecoded_probe(self):
        log = self.make_app_log()
        del log[3]["name"]
        with self.assertRaises(SystemExit):
            VERIFY.verify_reconnect_resubscribe(
                [adv_record(PROBE_TYPE, "wire-fixture")], log
            )


class CleanSessionContractTests(unittest.TestCase):
    def run_verify(self, connacks, tmp_path):
        connack_log = tmp_path / "connack.jsonl"
        connack_log.write_text(
            "".join(json.dumps(c) + "\n" for c in connacks), encoding="utf-8"
        )
        log = app_log(PROBE_STATES)
        log[3]["name"] = "wire-fixture"
        VERIFY.verify_clean_session(
            [adv_record(PROBE_TYPE, "wire-fixture")], log, connack_log=connack_log
        )

    def test_requires_two_clean_handshakes(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            self.run_verify(
                [{"sessionPresent": False}, {"sessionPresent": False}], tmp_path
            )
            with self.assertRaises(SystemExit):
                self.run_verify([{"sessionPresent": False}], tmp_path)
            with self.assertRaises(SystemExit):
                self.run_verify(
                    [{"sessionPresent": False}, {"sessionPresent": True}], tmp_path
                )

    def test_requires_the_connack_log(self):
        log = app_log(PROBE_STATES)
        log[3]["name"] = "wire-fixture"
        with self.assertRaises(SystemExit):
            VERIFY.verify_clean_session(
                [adv_record(PROBE_TYPE, "wire-fixture")], log, connack_log=None
            )


if __name__ == "__main__":
    unittest.main()
