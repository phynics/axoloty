#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Validate the machine-readable Axoloty test-tier contract."""

import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG = ROOT / "Tests" / "Support" / "test-tiers.json"
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


def fail(message):
    print(f"test-tier configuration error: {message}", file=sys.stderr)
    return 1


def main():
    config = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else CONFIG
    if len(sys.argv) > 2:
        return fail("usage: validate_test_tiers.py [config-path]")
    try:
        document = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return fail(str(error))

    if document.get("schemaVersion") != 1:
        return fail("schemaVersion must be 1")

    tiers = document.get("tiers")
    if not isinstance(tiers, list):
        return fail("tiers must be an array")

    ids = [tier.get("id") for tier in tiers if isinstance(tier, dict)]
    if len(ids) != len(tiers):
        return fail("every tier must be an object")
    if len(ids) != len(set(ids)):
        return fail("tier ids must be unique")
    if set(ids) != EXPECTED_TIERS:
        missing = sorted(EXPECTED_TIERS - set(ids))
        extra = sorted(set(ids) - EXPECTED_TIERS)
        return fail(f"tier set mismatch; missing={missing}, extra={extra}")

    required_fields = {"id", "timeoutSeconds", "cadence", "network", "required"}
    for tier in tiers:
        missing_fields = required_fields - set(tier)
        if missing_fields:
            return fail(f"{tier.get('id')}: missing fields {sorted(missing_fields)}")
        timeout = tier["timeoutSeconds"]
        if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
            return fail(f"{tier['id']}: timeoutSeconds must be a positive integer")
        if timeout > 3600:
            return fail(f"{tier['id']}: timeoutSeconds exceeds the one-hour policy")
        if tier["network"] not in NETWORK_MODES:
            return fail(f"{tier['id']}: unknown network mode {tier['network']!r}")
        if not isinstance(tier["required"], bool):
            return fail(f"{tier['id']}: required must be boolean")
        if not isinstance(tier["cadence"], str) or not tier["cadence"]:
            return fail(f"{tier['id']}: cadence must be a nonempty string")

    flake = document.get("flakePolicy", {})
    if flake.get("automaticRetries") != 0:
        return fail("automaticRetries must remain zero")
    if flake.get("diagnosticReruns") != 1:
        return fail("exactly one visible diagnostic rerun is allowed")
    if set(flake.get("quarantineRequires", [])) != {
        "owner", "ticket", "evidence", "deadline"
    }:
        return fail("quarantineRequires must name owner, ticket, evidence, and deadline")

    artifacts = document.get("artifactContract", {})
    if not {"manifest.json", "verifier.log"}.issubset(
        set(artifacts.get("requiredOnFailure", []))
    ):
        return fail("failure artifacts must include manifest.json and verifier.log")

    print(f"PASS: {len(tiers)} test tiers satisfy the Axoloty testing contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
