#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Verify decoded semantics for the `duplicate-reply` / `late-reply` scenarios.

Both scenarios are Axoloty (modern Swift) acting as a Call/Return initiator
against pinned CoatyJS 2.4.0 as the responder. This checks the independent
MQTT wire capture (what genuinely reached the broker) against the Axoloty
application log (what the subject actually reported doing), so a pass
requires the two views of the same run to agree -- not just that a process
exited 0.
"""

import argparse
import json
import sys
from pathlib import Path


def load_jsonl(path):
    records = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            records.append(json.loads(line))
    return records


def wire_topics(capture, segment):
    return [
        record["mqtt"]["topic"]
        for record in capture
        if f"/{segment}/" in record["mqtt"]["topic"] or record["mqtt"]["topic"].endswith(f"/{segment}")
    ]


def verify_duplicate_reply(capture, application_log):
    returns_on_wire = wire_topics(capture, "RTN")
    if len(returns_on_wire) < 2:
        raise SystemExit(
            f"Expected at least 2 wire RTN publishes (original + duplicate), found {len(returns_on_wire)}"
        )
    states = [record["state"] for record in application_log]
    if states.count("accepted") != 1 or states.count("ignored") != 1:
        raise SystemExit(f"Expected exactly one accepted and one ignored state, got {states}")
    accepted = next(r for r in application_log if r["state"] == "accepted")
    ignored = next(r for r in application_log if r["state"] == "ignored")
    if accepted.get("variant") != "original":
        raise SystemExit(f"Expected the accepted response to be the 'original' variant, got {accepted}")
    if ignored.get("variant") != "duplicate":
        raise SystemExit(f"Expected the ignored response to be the 'duplicate' variant, got {ignored}")


def verify_late_reply(capture, application_log):
    calls_on_wire = wire_topics(capture, "CLL:wire-fixture-operation") or [
        t for t in (r["mqtt"]["topic"] for r in capture) if "/CLL:wire-fixture-operation/" in t
    ]
    returns_on_wire = wire_topics(capture, "RTN")
    if not calls_on_wire:
        raise SystemExit("Expected a wire CLL publish for wire-fixture-operation, found none")
    if len(returns_on_wire) != 1:
        raise SystemExit(f"Expected exactly one late wire RTN publish, found {len(returns_on_wire)}")
    states = [record["state"] for record in application_log]
    if "gave-up" not in states:
        raise SystemExit(f"Expected Axoloty to report giving up on the Call, got {states}")
    if "accepted" in states or "ignored" in states:
        raise SystemExit(
            f"Axoloty must never observe the late Return at all (no active subscription), got {states}"
        )
    if states.index("gave-up") >= states.index("done"):
        raise SystemExit(f"Expected 'gave-up' to precede 'done', got {states}")


VERIFIERS = {
    "duplicate-reply": verify_duplicate_reply,
    "late-reply": verify_late_reply,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=sorted(VERIFIERS))
    parser.add_argument("capture", type=Path)
    parser.add_argument("application_log", type=Path)
    args = parser.parse_args()

    capture = load_jsonl(args.capture)
    application_log = load_jsonl(args.application_log)
    if not capture:
        raise SystemExit(f"Capture is empty: {args.capture}")
    if not application_log:
        raise SystemExit(f"Application log is empty: {args.application_log}")

    VERIFIERS[args.scenario](capture, application_log)
    print(f"OK: {args.scenario} verified against {len(capture)} wire records and {len(application_log)} app states")


if __name__ == "__main__":
    main()
