#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Validate the machine-readable Axoloty test-tier contract.

The contract lives in ``Tests/Support/test-tiers.json``. Beyond checking that
tier records are well formed, the validator also proves that the contract is
*executable*: every tier ``makeTarget`` and every ``selfTests`` owner resolves
to a real Makefile target, and every maintained ``Tests/**/test_*.py`` /
``Tests/**/test-*.sh`` self-test is owned by exactly one documented Make
target. This keeps the tier metadata honest about what CI actually invokes.
"""

import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Tests" / "Support" / "test-tiers.json"
MAKEFILE = ROOT / "Makefile"
TESTS_DIR = ROOT / "Tests"

EXPECTED_TIERS = {
    "smoke",
    "unit",
    "module",
    "property",
    "integration",
    "wire-offline",
    "wire-live",
    "nightly",
    "manual-macos",
}
NETWORK_MODES = {"none", "isolated", "isolated-broker", "isolated-containers"}
TIER_REQUIRED_FIELDS = {"id", "timeoutSeconds", "cadence", "network", "required"}
SELFTEST_REQUIRED_FIELDS = {"path", "makeTarget", "tier"}

# A Makefile target definition line: ``name:`` at column 0, but not a ``:=``
# variable assignment and not a special target such as ``.PHONY``.
_TARGET_RE = re.compile(r"^([A-Za-z0-9_][A-Za-z0-9_.-]*):(?!=)")


def parse_make_targets(makefile_path):
    """Return the set of user-defined Makefile targets in ``makefile_path``."""
    targets = set()
    path = pathlib.Path(makefile_path)
    if not path.is_file():
        return targets
    for line in path.read_text(encoding="utf-8").splitlines():
        match = _TARGET_RE.match(line)
        if not match:
            continue
        name = match.group(1)
        if name.startswith("."):
            continue
        targets.add(name)
    return targets


def discover_self_tests(tests_dir):
    """Return maintained self-test paths (posix, repo-relative) under ``tests_dir``.

    Paths are resolved relative to the parent of ``tests_dir`` so that, for the
    real contract, ``Tests`` maps to repo-relative ``Tests/...`` paths and the
    function stays testable against an isolated temp tree.
    """
    root = pathlib.Path(tests_dir)
    if not root.is_dir():
        return []
    base = root.parent
    found = []
    for pattern in ("test_*.py", "test-*.sh"):
        for path in root.rglob(pattern):
            if path.is_file():
                found.append(path.relative_to(base).as_posix())
    return sorted(set(found))


def validate(document, *, make_targets, discovered_self_tests, exists=None):
    """Return a list of contract error strings; an empty list means valid.

    ``make_targets`` is the set of real Makefile targets. ``discovered_self_tests``
    is the list of maintained self-test paths found on disk. ``exists`` is an
    optional predicate ``(path_string) -> bool`` used to confirm that mapped
    self-test files actually exist; it defaults to "always exists" so callers
    can test structure independently of the filesystem.
    """
    if exists is None:
        exists = lambda _path: True  # noqa: E731

    errors = []

    if document.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")

    tiers = document.get("tiers")
    if not isinstance(tiers, list):
        errors.append("tiers must be an array")
        return errors

    ids = [tier.get("id") for tier in tiers if isinstance(tier, dict)]
    if len(ids) != len(tiers):
        errors.append("every tier must be an object")
    if len(ids) != len(set(ids)):
        errors.append("tier ids must be unique")
    if set(ids) != EXPECTED_TIERS:
        missing = sorted(EXPECTED_TIERS - set(ids))
        extra = sorted(set(ids) - EXPECTED_TIERS)
        errors.append(f"tier set mismatch; missing={missing}, extra={extra}")

    known_ids = set(ids)
    for tier in tiers:
        if not isinstance(tier, dict):
            continue
        tier_id = tier.get("id")
        missing_fields = TIER_REQUIRED_FIELDS - set(tier)
        if missing_fields:
            errors.append(f"{tier_id}: missing fields {sorted(missing_fields)}")
            continue
        timeout = tier["timeoutSeconds"]
        if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
            errors.append(f"{tier_id}: timeoutSeconds must be a positive integer")
        elif timeout > 3600:
            errors.append(f"{tier_id}: timeoutSeconds exceeds the one-hour policy")
        if tier["network"] not in NETWORK_MODES:
            errors.append(f"{tier_id}: unknown network mode {tier['network']!r}")
        if not isinstance(tier["required"], bool):
            errors.append(f"{tier_id}: required must be boolean")
        if not isinstance(tier["cadence"], str) or not tier["cadence"]:
            errors.append(f"{tier_id}: cadence must be a nonempty string")
        make_target = tier.get("makeTarget")
        if make_target is not None:
            if not isinstance(make_target, str) or not make_target:
                errors.append(f"{tier_id}: makeTarget must be a nonempty string")
            elif make_target not in make_targets:
                errors.append(
                    f"{tier_id}: makeTarget {make_target!r} is not a Makefile target"
                )
        workflow = tier.get("workflow")
        if workflow is not None:
            if not isinstance(workflow, str) or not workflow:
                errors.append(f"{tier_id}: workflow must be a nonempty string")
            elif not exists(workflow):
                errors.append(f"{tier_id}: workflow {workflow!r} does not exist")

    flake = document.get("flakePolicy", {})
    if flake.get("automaticRetries") != 0:
        errors.append("automaticRetries must remain zero")
    if flake.get("diagnosticReruns") != 1:
        errors.append("exactly one visible diagnostic rerun is allowed")
    if set(flake.get("quarantineRequires", [])) != {
        "owner", "ticket", "evidence", "deadline"
    }:
        errors.append("quarantineRequires must name owner, ticket, evidence, and deadline")

    artifacts = document.get("artifactContract", {})
    if not {"manifest.json", "verifier.log"}.issubset(
        set(artifacts.get("requiredOnFailure", []))
    ):
        errors.append("failure artifacts must include manifest.json and verifier.log")

    errors.extend(
        _validate_self_tests(
            document.get("selfTests"),
            make_targets=make_targets,
            known_tiers=known_ids,
            discovered=discovered_self_tests,
            exists=exists,
        )
    )

    return errors


def _validate_self_tests(self_tests, *, make_targets, known_tiers, discovered, exists):
    errors = []
    if not isinstance(self_tests, list):
        errors.append("selfTests must be an array")
        return errors

    owned = {}
    for entry in self_tests:
        if not isinstance(entry, dict):
            errors.append("selfTests entries must be objects")
            continue
        missing_fields = SELFTEST_REQUIRED_FIELDS - set(entry)
        if missing_fields:
            errors.append(f"selfTest {entry.get('path') or '?'}: missing fields {sorted(missing_fields)}")
            continue
        path = entry["path"]
        make_target = entry["makeTarget"]
        tier_id = entry["tier"]
        if not isinstance(path, str) or not path:
            errors.append("selfTest path must be a nonempty string")
        if not isinstance(make_target, str) or not make_target:
            errors.append(f"selfTest {path or '?'}: makeTarget must be a nonempty string")
        elif make_target not in make_targets:
            errors.append(f"selfTest {path}: makeTarget {make_target!r} is not a Makefile target")
        if not isinstance(tier_id, str) or tier_id not in known_tiers:
            errors.append(f"selfTest {path}: tier {tier_id!r} is unknown")
        if isinstance(path, str) and path and not exists(path):
            errors.append(f"selfTest {path}: file does not exist")
        if isinstance(path, str) and path in owned:
            errors.append(
                f"selfTest {path}: duplicate ownership (also owned by {owned[path]!r})"
            )
        elif isinstance(path, str):
            owned[path] = make_target

    for found in discovered:
        if found not in owned:
            errors.append(
                f"unmapped self-test {found}: add it to selfTests with an owning makeTarget"
            )

    return errors


def main():
    config = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else CONFIG
    if len(sys.argv) > 2:
        print("usage: validate_test_tiers.py [config-path]", file=sys.stderr)
        return 1
    try:
        document = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"test-tier configuration error: {error}", file=sys.stderr)
        return 1

    make_targets = parse_make_targets(MAKEFILE)
    discovered = discover_self_tests(TESTS_DIR)
    errors = validate(
        document,
        make_targets=make_targets,
        discovered_self_tests=discovered,
        exists=lambda p: (ROOT / p).is_file(),
    )
    if errors:
        for error in errors:
            print(f"test-tier configuration error: {error}", file=sys.stderr)
        return 1

    tier_count = len(document.get("tiers", []))
    self_test_count = len(document.get("selfTests", []))
    print(
        f"PASS: {tier_count} test tiers and {self_test_count} self-tests "
        f"satisfy the Axoloty testing contract"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
