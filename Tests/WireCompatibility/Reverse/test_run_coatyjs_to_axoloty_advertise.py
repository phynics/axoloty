#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Host-side contract for the CoatyJS-to-Axoloty (JS -> modern) Advertise live runner."""

import pathlib
import unittest


HERE = pathlib.Path(__file__).resolve().parent


class CoatyJSToAxolotyAdvertiseRunnerContractTests(unittest.TestCase):
    def test_runner_starts_axoloty_as_the_detached_subscriber(self):
        runner = (HERE / "run-coatyjs-to-axoloty-advertise.sh").read_text(encoding="utf-8")

        self.assertIn("AxolotyAdvertiseConsumerTests", runner)
        self.assertIn("WIRE_JS_TO_MODERN_LIVE=1", runner)
        self.assertIn('"state":"ready"', runner)
        self.assertIn('"state":"ack"', runner)

    def test_runner_reuses_the_pinned_coatyjs_advertise_producer(self):
        runner = (HERE / "run-coatyjs-to-axoloty-advertise.sh").read_text(encoding="utf-8")

        self.assertIn("coatyjs-advertise-runner.js", runner)
        self.assertNotIn("coatyjs-advertise-consumer.js", runner)

    def test_consumer_asserts_decoded_semantics_not_only_delivery(self):
        consumer = (HERE / "AxolotyAdvertiseConsumerTests.swift").read_text(encoding="utf-8")

        self.assertIn("observeAdvertiseStream", consumer)
        self.assertIn('state\\":\\"ready', consumer)
        self.assertIn('state\\":\\"ack', consumer)
        for expectation in (
            "snapshot.object.coreType",
            "snapshot.object.objectType",
            "snapshot.object.objectId",
            "snapshot.object.name",
        ):
            self.assertIn(expectation, consumer)

    def test_consumer_is_disabled_outside_the_live_gate(self):
        consumer = (HERE / "AxolotyAdvertiseConsumerTests.swift").read_text(encoding="utf-8")

        self.assertIn('.enabled(if: ProcessInfo.processInfo.environment["WIRE_JS_TO_MODERN_LIVE"] == "1")', consumer)


if __name__ == "__main__":
    unittest.main()
