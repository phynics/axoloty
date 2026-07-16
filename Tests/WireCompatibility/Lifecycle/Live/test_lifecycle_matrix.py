#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Host-side contracts for the live lifecycle evidence matrix."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "lifecycle_matrix", HERE / "lifecycle-matrix.py"
)
MATRIX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATRIX)


class LifecycleMatrixContractTests(unittest.TestCase):
    def test_catalog_has_a_honest_live_disposition_for_every_scenario(self):
        required = {
            "offline-queueing", "reconnect-resubscribe", "broker-restart",
            "graceful-deadvertise", "unexpected-disconnect-last-will",
            "clean-session", "duplicate-reply", "late-reply", "qos-0",
            "qos-1", "qos-2",
        }
        self.assertEqual(set(MATRIX.SCENARIOS), required)
        for scenario in MATRIX.SCENARIOS.values():
            self.assertIn(scenario["status"], {"executable", "unsupported"})
            self.assertTrue(scenario["reason"])
            self.assertIn("axoloty", scenario["participants"])
            self.assertIn("coatyjs-2.4.0", scenario["participants"])

    def test_executable_result_requires_application_and_capture_evidence(self):
        scenario = MATRIX.SCENARIOS["unexpected-disconnect-last-will"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            application = root / "application.jsonl"
            capture = root / "capture.jsonl"
            application.write_text('{"state":"ready"}\n', encoding="utf-8")
            capture.write_text('{"sequence":1}\n', encoding="utf-8")
            manifest = MATRIX.evidence_manifest(scenario, application, capture)
        self.assertEqual(manifest["status"], "executed")
        self.assertEqual(set(manifest["evidence"]), {"applicationLog", "capture"})
        self.assertEqual(manifest["evidence"]["capture"]["records"], 1)

    def test_missing_capture_cannot_be_reported_as_an_execution(self):
        scenario = MATRIX.SCENARIOS["unexpected-disconnect-last-will"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            application = root / "application.jsonl"
            application.write_text('{"state":"ready"}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "capture"):
                MATRIX.evidence_manifest(scenario, application, root / "missing.jsonl")

    def test_unsupported_result_never_claims_a_capture(self):
        manifest = MATRIX.unsupported_manifest(MATRIX.SCENARIOS["qos-2"])
        self.assertEqual(manifest["status"], "unsupported")
        self.assertNotIn("evidence", manifest)
        self.assertIn("limitation", manifest)

    def test_shell_runner_uses_deadlines_and_retains_artifacts(self):
        runner = (HERE / "run-lifecycle-matrix.sh").read_text(encoding="utf-8")
        subject_runner = (HERE / "run-coatyjs-last-will.sh").read_text(encoding="utf-8")
        self.assertIn("lifecycle-matrix.py", runner)
        self.assertIn("--ready-file", subject_runner)
        self.assertIn("DEADLINE", runner)
        self.assertIn("application.jsonl", subject_runner)
        self.assertIn("coatyjs-last-will.jsonl", subject_runner)
        self.assertIn("manifest.json", runner)
        self.assertIn("verifier.log", runner)
        self.assertNotIn("sleep 0.5", runner)
        self.assertNotIn("sleep 1", runner)


if __name__ == "__main__":
    unittest.main()
