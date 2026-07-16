#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Host-runnable contract checks for the macOS-only legacy capture runner."""

from pathlib import Path
import unittest


LEGACY_DIRECTORY = Path(__file__).parent
RUNNER_SOURCE = LEGACY_DIRECTORY / "macOS-runner/Sources/LegacyCoatySwiftScenarioRunner/main.swift"
ORCHESTRATOR = LEGACY_DIRECTORY / "run_capture_on_macos.sh"
RUNNER_README = LEGACY_DIRECTORY / "macOS-runner/README.md"
PIN_VERIFIER = LEGACY_DIRECTORY / "macOS-runner/verify-pin.sh"
PACKAGE_RESOLVED = LEGACY_DIRECTORY / "macOS-runner/Package.resolved"
PINNED_COMMIT = "20a97b29832758fb771ac79fd5f7ae36cff69403"


class MacOSRunnerContractTests(unittest.TestCase):
    def test_runner_declares_all_supported_scenarios(self):
        source = RUNNER_SOURCE.read_text(encoding="utf-8")

        for scenario in ("advertise", "deadvertise", "discover-resolve"):
            self.assertIn(f'"{scenario}"', source)

    def test_runner_uses_deterministic_discover_resolve_identities_and_object(self):
        source = RUNNER_SOURCE.read_text(encoding="utf-8")

        for identifier in (
            "00000000-0000-4000-8000-000000000101",
            "00000000-0000-4000-8000-000000000201",
            "00000000-0000-4000-8000-000000000202",
        ):
            self.assertIn(identifier, source)
        self.assertIn("org.axoloty.wire.ReferenceObject", source)
        self.assertIn('"reference": "coatyswift-2.4.0"', source)

    def test_orchestrator_derives_publication_count_from_scenario(self):
        source = ORCHESTRATOR.read_text(encoding="utf-8")

        self.assertIn("case \"$SCENARIO\" in", source)
        self.assertIn("advertise) DEFAULT_EXPECTED_PUBLICATIONS=2", source)
        self.assertIn("deadvertise) DEFAULT_EXPECTED_PUBLICATIONS=2", source)
        self.assertIn("discover-resolve) DEFAULT_EXPECTED_PUBLICATIONS=4", source)
        self.assertIn('"$EXPECTED_PUBLICATIONS"', source)

    def test_orchestrator_waits_for_probe_subscription_before_starting_runner(self):
        source = ORCHESTRATOR.read_text(encoding="utf-8")

        self.assertIn('CAPTURE_READY="$OUTPUT_DIR/$SCENARIO.capture-ready"', source)
        self.assertIn('--ready-file "$CAPTURE_READY"', source)
        self.assertIn('while [ ! -f "$CAPTURE_READY" ]; do', source)
        self.assertIn('Capture probe did not become ready', source)
        self.assertLess(
            source.index('while [ ! -f "$CAPTURE_READY" ]; do'),
            source.index('"$LEGACY_SCENARIO_COMMAND"'),
        )

    def test_runner_documentation_gives_capture_commands_for_every_scenario(self):
        readme = RUNNER_README.read_text(encoding="utf-8")

        for scenario in ("advertise", "deadvertise", "discover-resolve"):
            self.assertIn(f"SCENARIO={scenario}", readme)
        self.assertIn("lossless JSONL capture", readme)
        self.assertIn("provenance manifest", readme)

    def test_pin_verification_has_a_committed_lockfile_for_the_compiled_revision(self):
        verifier = PIN_VERIFIER.read_text(encoding="utf-8")

        self.assertTrue(PACKAGE_RESOLVED.is_file())
        self.assertIn(PINNED_COMMIT, PACKAGE_RESOLVED.read_text(encoding="utf-8"))
        self.assertIn('RESOLVED="$SCRIPT_DIR/Package.resolved"', verifier)
        self.assertIn(PINNED_COMMIT, verifier)


if __name__ == "__main__":
    unittest.main()
