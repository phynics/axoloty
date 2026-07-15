#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Render aggregate and informational changed-line LLVM coverage."""

import argparse
import json
import os
import pathlib
import re
import sys

import coverage_ratchet


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def load_export(path):
    """Load and decode an LLVM export JSON document."""
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def extract_line_coverage(document):
    """Return ``{Source/path: {line: covered}}`` from LLVM segments."""
    data = document.get("data")
    if not isinstance(data, list):
        raise ValueError("LLVM coverage export data must be an array")
    files = {}
    for bundle in data:
        for entry in bundle.get("files", []):
            path = coverage_ratchet.normalize_source_path(entry.get("filename", ""))
            if path is None:
                continue
            lines = {}
            for segment in entry.get("segments", []):
                if len(segment) < 4:
                    continue
                line = int(segment[0])
                count = int(segment[2])
                has_count = bool(segment[3])
                is_gap = bool(segment[5]) if len(segment) > 5 else False
                if has_count and not is_gap:
                    lines[line] = lines.get(line, False) or count > 0
            files[path] = lines
    return files


def parse_changed_lines(diff_text):
    """Return changed added-line numbers for production Swift files."""
    changed = {}
    path = None
    current_line = None
    for raw_line in diff_text.splitlines():
        if raw_line.startswith("+++ b/"):
            path = raw_line[6:]
            if not path.startswith("Source/"):
                path = None
            current_line = None
            continue
        match = HUNK_RE.match(raw_line)
        if match:
            current_line = int(match.group(1))
            continue
        if path is None or current_line is None or raw_line.startswith("\\"):
            continue
        if raw_line.startswith("+"):
            changed.setdefault(path, set()).add(current_line)
            current_line += 1
        elif raw_line.startswith("-"):
            continue
        else:
            current_line += 1
    return changed


def _percent(covered, count):
    return round(100.0 * covered / count, 2) if count else 0.0


def summarize(export_path, diff_path, baseline_path):
    """Build a stable aggregate, changed-line, and regression summary."""
    document = load_export(export_path)
    line_files = extract_line_coverage(document)
    current_files = coverage_ratchet.extract(export_path)
    diff_text = pathlib.Path(diff_path).read_text(encoding="utf-8") if diff_path else ""
    changed = parse_changed_lines(diff_text)
    changed_covered = 0
    changed_count = 0
    uncovered = []
    for path, lines in changed.items():
        executable = set(line_files.get(path, {})).intersection(lines)
        changed_count += len(executable)
        changed_covered += sum(line_files[path][line] for line in executable)
        uncovered.extend((path, line) for line in sorted(executable) if not line_files[path][line])

    baseline = json.loads(pathlib.Path(baseline_path).read_text(encoding="utf-8"))
    covered, count, percent = coverage_ratchet.aggregate(current_files)
    regressions = []
    for path, baseline_entry in baseline.get("files", {}).items():
        current_entry = current_files.get(path)
        if not current_entry or not current_entry["count"]:
            continue
        baseline_percent = _percent(baseline_entry["covered"], baseline_entry["count"])
        current_percent = _percent(current_entry["covered"], current_entry["count"])
        if current_percent < baseline_percent:
            regressions.append({
                "path": path,
                "baseline": baseline_percent,
                "current": current_percent,
                "delta": round(current_percent - baseline_percent, 2),
            })
    regressions.sort(key=lambda entry: (entry["delta"], entry["path"]))
    return {
        "aggregate": {"covered": covered, "count": count, "percent": round(percent, 2)},
        "baseline": float(baseline.get("_aggregate", {}).get("percent", 0.0)),
        "changed": {
            "covered": changed_covered,
            "count": changed_count,
            "percent": _percent(changed_covered, changed_count),
        },
        "regressions": regressions[:10],
        "uncovered": sorted(uncovered),
    }


def render_markdown(summary):
    """Render the summary as GitHub-flavored Markdown."""
    aggregate = summary["aggregate"]
    changed = summary["changed"]
    delta = aggregate["percent"] - summary["baseline"]
    lines = [
        "## Source coverage",
        "",
        "| Metric | Value |",
        "| --- | ---: |",
        f"| Aggregate | {aggregate['covered']}/{aggregate['count']} ({aggregate['percent']:.2f}%) |",
        f"| Baseline delta | {delta:+.2f} percentage points |",
        f"| Changed executable lines | {changed['covered']}/{changed['count']} ({changed['percent']:.2f}%) |",
    ]
    if summary["regressions"]:
        lines.extend(["", "### Largest file-level decreases", ""])
        for entry in summary["regressions"]:
            lines.append(f"- `{entry['path']}`: {entry['current']:.2f}% ({entry['delta']:+.2f} pp)")
    if summary["uncovered"]:
        lines.extend(["", f"Informational warnings: {len(summary['uncovered'])} changed executable lines are uncovered."])
    return "\n".join(lines) + "\n"


def emit_annotations(summary, limit=20):
    """Emit at most ``limit`` native workflow warnings."""
    for path, line in summary.get("uncovered", [])[:limit]:
        print(f"::warning file={path},line={line}::Changed executable line is not covered")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export")
    parser.add_argument("diff")
    parser.add_argument("--baseline", default="Tests/Support/coverage-baseline.json")
    parser.add_argument("--annotation-limit", type=int, default=20)
    parser.add_argument("--no-summary-file", action="store_true")
    args = parser.parse_args(argv)
    summary = summarize(args.export, args.diff, args.baseline)
    markdown = render_markdown(summary)
    print(markdown, end="")
    if not args.no_summary_file:
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as stream:
                stream.write(markdown)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        emit_annotations(summary, max(args.annotation_limit, 0))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
