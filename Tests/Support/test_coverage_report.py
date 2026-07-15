#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Tests for informational source and changed-line coverage reporting."""

import contextlib
import io
import json
import pathlib
import tempfile
import unittest

import coverage_report as report


def export_document():
    return {
        "data": [{
            "files": [
                {
                    "filename": "/workspace/Source/A.swift",
                    "summary": {"lines": {"count": 4, "covered": 2}},
                    "segments": [
                        [1, 1, 3, True, True, False],
                        [2, 1, 0, True, True, False],
                        [3, 1, 0, True, True, False],
                        [4, 1, 0, False, False, True],
                    ],
                },
                {
                    "filename": "/workspace/Tests/SomeTest.swift",
                    "summary": {"lines": {"count": 2, "covered": 2}},
                    "segments": [[1, 1, 1, True, True, False]],
                },
            ]
        }]
    }


class CoverageReportTests(unittest.TestCase):
    def test_extracts_source_lines_and_ignores_gap_regions(self):
        files = report.extract_line_coverage(export_document())
        self.assertEqual(files, {"Source/A.swift": {1: True, 2: False, 3: False}})

    def test_parses_added_lines_and_ignores_deleted_lines(self):
        diff = """diff --git a/Source/A.swift b/Source/A.swift
--- a/Source/A.swift
+++ b/Source/A.swift
@@ -1,3 +1,4 @@
 line one
-removed
+added
 line three
"""
        self.assertEqual(report.parse_changed_lines(diff), {"Source/A.swift": {2}})

    def test_summarizes_changed_line_coverage_and_regressions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            export_path = root / "coverage.json"
            diff_path = root / "changed.diff"
            baseline_path = root / "baseline.json"
            export_path.write_text(json.dumps(export_document()), encoding="utf-8")
            diff_path.write_text(
                "+++ b/Source/A.swift\n@@ -1,1 +1,3 @@\n+added\n+added again\n",
                encoding="utf-8",
            )
            baseline_path.write_text(json.dumps({
                "_aggregate": {"percent": 50.0},
                "files": {"Source/A.swift": {"count": 4, "covered": 3}},
            }), encoding="utf-8")
            summary = report.summarize(export_path, diff_path, baseline_path)
        self.assertEqual(summary["changed"], {"covered": 1, "count": 2, "percent": 50.0})
        self.assertEqual(summary["aggregate"]["percent"], 50.0)
        self.assertEqual(summary["regressions"][0]["path"], "Source/A.swift")

    def test_annotation_output_is_capped(self):
        summary = {
            "uncovered": [("Source/A.swift", line) for line in range(1, 5)],
        }
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            report.emit_annotations(summary, limit=2)
        self.assertEqual(output.getvalue().count("::warning"), 2)

    def test_rejects_malformed_export(self):
        with self.assertRaises(ValueError):
            report.extract_line_coverage({"data": "not-a-list"})


if __name__ == "__main__":
    unittest.main()
