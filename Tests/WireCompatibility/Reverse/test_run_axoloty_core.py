#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Host-side contracts for the Axoloty-to-CoatyJS core live runner."""

import pathlib
import unittest


HERE = pathlib.Path(__file__).resolve().parent


class AxolotyCoreRunnerContractTests(unittest.TestCase):
    def test_runner_covers_only_the_axoloty_to_coatyjs_core_matrix(self):
        runner = (HERE / "run-axoloty-core.sh").read_text(encoding="utf-8")

        self.assertIn("AxolotyCoreProducerTests", runner)
        self.assertIn("coatyjs-core-consumer.js", runner)
        self.assertIn("--producer coatyswift-modern", runner)
        self.assertIn("--producer-version current", runner)
        self.assertIn("WIRE_SCENARIOS", runner)
        self.assertNotIn("run-coatyjs-core.sh", runner)

    def test_runner_identifies_the_modern_coatyswift_producer(self):
        runner = (HERE / "run-axoloty-core.sh").read_text(encoding="utf-8")

        self.assertIn("--producer coatyswift-modern", runner)
        self.assertNotIn("--producer axoloty-modern", runner)

    def test_request_response_producer_asserts_decoded_axoloty_streams(self):
        producer = (HERE / "AxolotyCoreProducerTests.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("awaitResponse", producer)
        self.assertIn("PayloadCoder.decode", producer)
        for event in ("ResolveEvent", "RetrieveEvent", "CompleteEvent", "ReturnEvent"):
            self.assertIn(event, producer)

    def test_consumer_acknowledges_every_required_coatyjs_decode(self):
        consumer = (HERE / "coatyjs-core-consumer.js").read_text(encoding="utf-8")

        for scenario in (
            "deadvertise",
            "channel",
            "discover-resolve",
            "query-retrieve",
            "update-complete",
            "call-return",
        ):
            self.assertIn(scenario, consumer)
        self.assertIn('state: "ack"', consumer)
        self.assertIn("observeDeadvertise", consumer)
        self.assertIn("observeChannel", consumer)
        self.assertIn("observeDiscover", consumer)
        self.assertIn("observeQuery", consumer)
        self.assertIn("observeUpdateWithObjectType", consumer)
        self.assertIn("observeCall", consumer)


if __name__ == "__main__":
    unittest.main()
