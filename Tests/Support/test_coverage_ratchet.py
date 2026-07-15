#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Self-tests for the source-coverage ratchet."""

import copy
import json
import pathlib
import tempfile
import unittest

import coverage_ratchet as cr


def baseline(file_entries, percent=None):
    if percent is None:
        _, _, percent = cr.aggregate(file_entries)
    return {"schemaVersion": 1, "_aggregate": {"covered": 0, "count": 0, "percent": percent}, "files": file_entries}


class EvaluateTests(unittest.TestCase):
    def test_unchanged_coverage_passes(self):
        current = {"Source/A.swift": {"count": 10, "covered": 6}, "Source/B.swift": {"count": 20, "covered": 10}}
        self.assertEqual(cr.evaluate(current, baseline(copy.deepcopy(current))), [])

    def test_aggregate_drop_beyond_policy_fails(self):
        current = {"Source/A.swift": {"count": 100, "covered": 60}}
        base = baseline({"Source/A.swift": {"count": 100, "covered": 80}}, percent=80.0)
        errors = cr.evaluate(current, base)
        self.assertTrue(any("aggregate coverage dropped" in e for e in errors))

    def test_small_aggregate_drop_within_policy_passes(self):
        # A new mostly-uncovered file lowers the aggregate slightly but does not
        # regress any existing file's covered lines, so the ratchet passes.
        current = {
            "Source/A.swift": {"count": 100, "covered": 80},
            "Source/New.swift": {"count": 1, "covered": 0},
        }
        base = baseline({"Source/A.swift": {"count": 100, "covered": 80}}, percent=80.0)
        self.assertEqual(cr.evaluate(current, base), [])

    def test_per_file_covered_regression_is_informational(self):
        current = {"Source/A.swift": {"count": 100, "covered": 79}, "Source/B.swift": {"count": 10, "covered": 6}}
        base = baseline({
            "Source/A.swift": {"count": 100, "covered": 80},
            "Source/B.swift": {"count": 10, "covered": 5},
        }, percent=85 / 110 * 100)
        self.assertEqual(cr.evaluate(current, base), [])

    def test_new_file_does_not_fail_per_file_rule(self):
        current = {
            "Source/A.swift": {"count": 100, "covered": 80},
            "Source/New.swift": {"count": 50, "covered": 0},
        }
        base = baseline({"Source/A.swift": {"count": 100, "covered": 80}}, percent=80.0)
        errors = cr.evaluate(current, base)
        # New file lowers aggregate from 80% to ~53%, which exceeds policy and
        # is reported as an aggregate drop, not a per-file regression.
        self.assertTrue(any("aggregate coverage dropped" in e for e in errors))
        self.assertFalse(any("New.swift" in e and "regressed" in e for e in errors))

    def test_deleted_file_does_not_fail(self):
        current = {"Source/A.swift": {"count": 100, "covered": 80}}
        base = baseline({
            "Source/A.swift": {"count": 100, "covered": 80},
            "Source/Gone.swift": {"count": 10, "covered": 5},
        }, percent=80.0)
        self.assertEqual(cr.evaluate(current, base), [])


class ExtractTests(unittest.TestCase):
    def _export(self, file_entries):
        return {"data": [{"files": [
            {"filename": name, "summary": {"lines": {"count": c, "covered": v, "percent": 0}}}
            for name, (c, v) in file_entries
        ]}]}

    def test_keeps_only_source_files_and_normalizes_paths(self):
        export = self._export([
            ("/workspace/Source/Common/Foo.swift", (10, 6)),
            ("/workspace/Tests/SomeTest.swift", (20, 20)),
            ("/workspace/Source/IORouting/IoRouter.swift", (100, 40)),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "cov.json"
            path.write_text(json.dumps(export), encoding="utf-8")
            extracted = cr.extract(path)
        self.assertEqual(set(extracted), {"Source/Common/Foo.swift", "Source/IORouting/IoRouter.swift"})
        self.assertEqual(extracted["Source/Common/Foo.swift"], {"count": 10, "covered": 6})


if __name__ == "__main__":
    unittest.main()
