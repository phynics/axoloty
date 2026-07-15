#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Source-coverage ratchet for the Axoloty package.

Consumes the JSON emitted by ``llvm-cov export`` (run via
``swift test --enable-code-coverage``) and compares it against a committed
baseline. Only ``Source/`` production files contribute to the denominator;
tests, dependencies, generated code, and reference agents are excluded.

The ratchet fails when aggregate ``Source/`` line coverage drops by more than
1.0 percentage point. A clean run records aggregate and per-file line/region
coverage under ``.testing/coverage/``; informational changed-line reporting is
handled by ``coverage_report.py``.
"""

import argparse
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
BASELINE = ROOT / "Tests" / "Support" / "coverage-baseline.json"
MAX_AGGREGATE_DROP = 1.0


def normalize_source_path(filename):
    """Return the repo-relative ``Source/...`` path, or ``None`` if not source.

    llvm-cov reports absolute build paths such as
    ``/workspace/Source/Common/Foo.swift``. We keep only paths under
    ``Source/`` so tests, dependencies, and plugin code are excluded from the
    denominator regardless of where the build ran.
    """
    marker = "/Source/"
    idx = filename.rfind(marker)
    if idx == -1:
        return None
    return filename[idx + 1:]


def extract(coverage_json_path, source_root=None):
    """Read an llvm-cov export JSON file and return ``{path: {count, covered}}``.

    Only ``Source/`` production files are included. Paths are repo-relative
    (``Source/...``). ``source_root`` is accepted for symmetry/testability but
    the normalization is path-fragment based, so it is not required.
    """
    document = json.loads(pathlib.Path(coverage_json_path).read_text(encoding="utf-8"))
    files = {}
    for data in document.get("data", []):
        for entry in data.get("files", []):
            path = normalize_source_path(entry.get("filename", ""))
            if path is None:
                continue
            lines = entry.get("summary", {}).get("lines", {})
            files[path] = {
                "count": int(lines.get("count", 0)),
                "covered": int(lines.get("covered", 0)),
            }
    return files


def aggregate(files):
    """Return ``(covered, count, percent)`` for a per-file coverage dict."""
    covered = sum(f["covered"] for f in files.values())
    count = sum(f["count"] for f in files.values())
    percent = (100.0 * covered / count) if count else 0.0
    return covered, count, percent


def evaluate(current_files, baseline, max_drop=MAX_AGGREGATE_DROP):
    """Return aggregate ratchet errors; an empty list means the check passes."""
    errors = []

    if "_aggregate" in baseline:
        baseline_percent = float(baseline["_aggregate"].get("percent", 0.0))
    else:
        _, _, baseline_percent = aggregate(baseline.get("files", {}))

    _, _, current_percent = aggregate(current_files)
    drop = baseline_percent - current_percent
    if drop > max_drop:
        errors.append(
            f"aggregate coverage dropped from {baseline_percent:.2f}% to "
            f"{current_percent:.2f}% ({drop:.2f}pp exceeds {max_drop:.2f}pp)"
        )

    return errors


def write_report(files, output_path):
    """Write the per-file coverage report and a human-readable summary."""
    covered, count, percent = aggregate(files)
    output_path = pathlib.Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    envelope = {
        "schemaVersion": 1,
        "_aggregate": {"covered": covered, "count": count, "percent": round(percent, 4)},
        "files": dict(sorted(files.items())),
    }
    output_path.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
    summary_path = output_path.with_suffix(".txt")
    summary_path.write_text(
        f"Axoloty source coverage: {covered}/{count} lines ({percent:.2f}%)\n"
        f"Files measured: {len(files)}\n",
        encoding="utf-8",
    )
    return percent


def main(argv=None):
    parser = argparse.ArgumentParser(description="Axoloty coverage ratchet")
    sub = parser.add_subparsers(dest="command", required=True)
    p_summary = sub.add_parser("summary", help="Print aggregate coverage from an llvm-cov export")
    p_summary.add_argument("coverage_json")
    p_summary.add_argument("--report", help="Optional path to write the per-file report")
    p_check = sub.add_parser("check", help="Compare current coverage against the committed baseline")
    p_check.add_argument("coverage_json")
    p_check.add_argument("baseline", nargs="?", default=str(BASELINE))

    args = parser.parse_args(argv)

    if args.command == "summary":
        files = extract(args.coverage_json)
        covered, count, percent = aggregate(files)
        if args.report:
            write_report(files, args.report)
        print(f"Axoloty source coverage: {covered}/{count} lines ({percent:.2f}%)")
        print(f"Files measured: {len(files)}")
        return 0

    if args.command == "check":
        files = extract(args.coverage_json)
        baseline = json.loads(pathlib.Path(args.baseline).read_text(encoding="utf-8"))
        errors = evaluate(files, baseline)
        if errors:
            for error in errors:
                print(f"coverage ratchet: {error}", file=sys.stderr)
            return 1
        _, _, current_percent = aggregate(files)
        baseline_percent = float(baseline.get("_aggregate", {}).get("percent", 0.0))
        print(
            f"PASS: source coverage {current_percent:.2f}% "
            f"(baseline {baseline_percent:.2f}%, ratchet within policy)"
        )
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
