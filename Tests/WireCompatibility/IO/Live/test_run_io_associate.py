#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Host-side contract for the IO Associate live runner (modern -> JS)."""

import pathlib
import unittest


HERE = pathlib.Path(__file__).resolve().parent
RUNNER = HERE / "run-io-associate.sh"
SWIFT_TEST = (HERE / ".." / "AxolotyIoAssociateTests.swift").resolve()


class IoAssociateRunnerContractTests(unittest.TestCase):
    def test_runner_starts_coatyjs_actor_before_axoloty_producer(self):
        text = RUNNER.read_text(encoding="utf-8")

        self.assertIn("ROLE=actor", text)
        self.assertIn("IO_EXPECTED_VALUES=1", text)
        self.assertIn('"state":"ready"', text)
        self.assertIn('"state":"ack"', text)
        self.assertIn("WIRE_IO_MODERN_TO_JS_LIVE=1", text)
        self.assertIn("AxolotyIoAssociateTests", text)

    def test_runner_reuses_the_pinned_coatyjs_io_runner(self):
        text = RUNNER.read_text(encoding="utf-8")

        self.assertIn("coatyjs-io-runner.js", text)

    def test_runner_captures_the_wire(self):
        text = RUNNER.read_text(encoding="utf-8")

        self.assertIn("mqtt_capture.py", text)
        self.assertIn("io-associate.jsonl", text)

    def test_producer_asserts_decoded_semantics_not_only_delivery(self):
        text = SWIFT_TEST.read_text(encoding="utf-8")

        # The offline cases lock in the wire format the live runner exercises.
        self.assertIn("createIoRoute", text)
        self.assertIn("publishAssociate", text)
        self.assertIn("publishIoValue", text)
        self.assertIn('WIRE_IO_MODERN_TO_JS_LIVE', text)

    def test_producer_is_disabled_outside_the_live_gate(self):
        text = SWIFT_TEST.read_text(encoding="utf-8")

        self.assertIn(
            '.enabled(if: ProcessInfo.processInfo.environment["WIRE_IO_MODERN_TO_JS_LIVE"] == "1")',
            text,
        )

    def test_runner_uses_a_generous_actor_timeout_for_cold_builds(self):
        text = RUNNER.read_text(encoding="utf-8")

        # The Axoloty producer's in-container cold build (e.g. in CI, where the
        # build cache is workspace-local and cold) can take several minutes
        # before it publishes; the actor must outlast that window.
        self.assertIn("SCENARIO_TIMEOUT_MS=600000", text)


if __name__ == "__main__":
    unittest.main()
