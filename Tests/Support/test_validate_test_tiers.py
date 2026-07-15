#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Self-tests for the test-tier contract validator."""

import copy
import pathlib
import tempfile
import unittest

import validate_test_tiers as vtt


def valid_document():
    return {
        "schemaVersion": 1,
        "tiers": [
            {"id": "smoke", "timeoutSeconds": 300, "cadence": "pull-request", "network": "none", "required": True, "makeTarget": "build"},
            {"id": "unit", "timeoutSeconds": 120, "cadence": "pull-request", "network": "none", "required": True, "makeTarget": "test-unit"},
            {"id": "module", "timeoutSeconds": 300, "cadence": "pull-request", "network": "isolated", "required": True, "makeTarget": "test-module"},
            {"id": "property", "timeoutSeconds": 600, "cadence": "pull-request-bounded", "network": "none", "required": True, "makeTarget": "test-fuzz"},
            {"id": "integration", "timeoutSeconds": 600, "cadence": "pull-request", "network": "isolated-broker", "required": True, "makeTarget": "test"},
            {"id": "wire-offline", "timeoutSeconds": 300, "cadence": "pull-request", "network": "none", "required": True, "makeTarget": "test-wire"},
            {"id": "wire-live", "timeoutSeconds": 1200, "cadence": "protocol-change-and-pre-merge", "network": "isolated-containers", "required": True, "makeTarget": "test-wire-live"},
            {"id": "nightly", "timeoutSeconds": 3600, "cadence": "nightly-and-release", "network": "isolated-containers", "required": False, "makeTarget": "fuzz-long"},
            {"id": "manual-macos", "timeoutSeconds": 1800, "cadence": "release-and-apple-change", "network": "isolated-broker", "required": False},
        ],
        "selfTests": [
            {"path": "Tests/Fuzzing/test-run-fuzz.sh", "makeTarget": "test-support", "tier": "property"},
            {"path": "Tests/WireCompatibility/Capture/test_mqtt_capture.py", "makeTarget": "test-support", "tier": "wire-offline"},
            {"path": "Tests/WireCompatibility/Legacy/test_legacy_capture.py", "makeTarget": "test-support", "tier": "wire-offline"},
            {"path": "Tests/WireCompatibility/Live/test_verify_coatyjs_core.py", "makeTarget": "test-support", "tier": "wire-live"},
            {"path": "Tests/Support/test_validate_test_tiers.py", "makeTarget": "test-support", "tier": "unit"},
        ],
        "artifactContract": {
            "requiredOnFailure": ["manifest.json", "verifier.log"],
            "brokerScenarios": ["capture.jsonl", "mosquitto.log"],
            "interopScenarios": ["axoloty.log", "coatyjs.log"],
            "generatedScenarios": ["seed.txt", "reproducer"],
        },
        "flakePolicy": {
            "automaticRetries": 0,
            "diagnosticReruns": 1,
            "quarantineRequires": ["owner", "ticket", "evidence", "deadline"],
        },
    }


def valid_make_targets():
    return {
        "test-unit", "test-module", "test-fuzz", "test", "test-wire",
        "test-wire-live", "fuzz-long", "test-support", "build", "ci",
    }


def valid_discovered():
    return [
        "Tests/Fuzzing/test-run-fuzz.sh",
        "Tests/Support/test_validate_test_tiers.py",
        "Tests/WireCompatibility/Capture/test_mqtt_capture.py",
        "Tests/WireCompatibility/Legacy/test_legacy_capture.py",
        "Tests/WireCompatibility/Live/test_verify_coatyjs_core.py",
    ]


class ValidateTestTiersTests(unittest.TestCase):
    def test_valid_contract_passes(self):
        errors = vtt.validate(
            valid_document(),
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
        )
        self.assertEqual(errors, [])

    def test_tier_make_target_must_be_a_real_makefile_target(self):
        document = valid_document()
        document["tiers"][1]["makeTarget"] = "no-such-target"
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
        )
        self.assertTrue(any("unit" in e and "no-such-target" in e for e in errors))

    def test_self_test_with_unknown_make_target_fails(self):
        document = valid_document()
        document["selfTests"][0]["makeTarget"] = "ghost-target"
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
        )
        self.assertTrue(any("ghost-target" in e for e in errors))

    def test_self_test_with_unknown_tier_fails(self):
        document = valid_document()
        document["selfTests"][0]["tier"] = "imaginary"
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
        )
        self.assertTrue(any("imaginary" in e for e in errors))

    def test_self_test_missing_metadata_fails(self):
        document = valid_document()
        del document["selfTests"][0]["makeTarget"]
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
        )
        self.assertTrue(any("missing fields" in e for e in errors))

    def test_nonexistent_self_test_path_fails(self):
        document = valid_document()
        document["selfTests"][0]["path"] = "Tests/Fuzzing/does-not-exist.sh"
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
            exists=lambda p: p != "Tests/Fuzzing/does-not-exist.sh",
        )
        self.assertTrue(any("does-not-exist.sh" in e and "does not exist" in e for e in errors))

    def test_duplicate_ownership_fails(self):
        document = valid_document()
        duplicate = copy.deepcopy(document["selfTests"][0])
        document["selfTests"].append(duplicate)
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
        )
        self.assertTrue(any("duplicate ownership" in e for e in errors))

    def test_unmapped_maintained_self_test_fails(self):
        document = valid_document()
        discovered = valid_discovered() + ["Tests/Unmapped/test_something.py"]
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=discovered,
        )
        self.assertTrue(any("Unmapped" in e and "unmapped self-test" in e for e in errors))

    def test_self_tests_must_be_an_array(self):
        document = valid_document()
        document["selfTests"] = "nope"
        errors = vtt.validate(
            document,
            make_targets=valid_make_targets(),
            discovered_self_tests=valid_discovered(),
        )
        self.assertTrue(any("selfTests must be an array" in e for e in errors))


class ParseMakeTargetsTests(unittest.TestCase):
    def test_parses_targets_and_excludes_special_targets_and_assignments(self):
        with tempfile.TemporaryDirectory() as tmp:
            makefile = pathlib.Path(tmp) / "Makefile"
            makefile.write_text(
                "VAR := value\n"
                "OTHER = other\n"
                ".PHONY: build test\n"
                "build:\n"
                "\t@echo hi\n"
                "test: build\n"
                "test-support: image\n"
                "\tbash run.sh\n"
                "# comment: not-a-target\n"
                "name.with.dots: dep\n",
                encoding="utf-8",
            )
            targets = vtt.parse_make_targets(makefile)
        self.assertIn("build", targets)
        self.assertIn("test", targets)
        self.assertIn("test-support", targets)
        self.assertIn("name.with.dots", targets)
        self.assertNotIn(".PHONY", targets)
        self.assertNotIn("VAR", targets)
        self.assertNotIn("OTHER", targets)
        self.assertNotIn("comment", targets)

    def test_missing_makefile_returns_empty_set(self):
        self.assertEqual(vtt.parse_make_targets(pathlib.Path("/nonexistent/Makefile")), set())


class DiscoverSelfTestsTests(unittest.TestCase):
    def test_discovers_python_and_shell_self_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tests = root / "Tests" / "Fuzzing"
            tests.mkdir(parents=True)
            (tests / "test-run-fuzz.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            (tests / "runner.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            sub = root / "Tests" / "Wire" / "Capture"
            sub.mkdir(parents=True)
            (sub / "test_mqtt_capture.py").write_text("pass\n", encoding="utf-8")
            (sub / "helper.py").write_text("pass\n", encoding="utf-8")
            # Paths are repo-relative to the parent of the supplied Tests directory.
            discovered = vtt.discover_self_tests(root / "Tests")
        names = [pathlib.Path(p).name for p in discovered]
        self.assertIn("test-run-fuzz.sh", names)
        self.assertIn("test_mqtt_capture.py", names)
        self.assertNotIn("runner.sh", names)
        self.assertNotIn("helper.py", names)


if __name__ == "__main__":
    unittest.main()
