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
from datetime import datetime
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


def parse_utc(value):
    """Parse an ISO-8601 UTC timestamp with or without fractional seconds."""
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def verify_late_reply(capture, application_log):
    calls_on_wire = wire_topics(capture, "CLL:wire-fixture-operation")
    return_records = [
        record
        for record in capture
        if "/RTN/" in record["mqtt"]["topic"] or record["mqtt"]["topic"].endswith("/RTN")
    ]
    if not calls_on_wire:
        raise SystemExit("Expected a wire CLL publish for wire-fixture-operation, found none")
    if len(return_records) != 1:
        raise SystemExit(f"Expected exactly one late wire RTN publish, found {len(return_records)}")
    states = [record["state"] for record in application_log]
    if "gave-up" not in states:
        raise SystemExit(f"Expected Axoloty to report giving up on the Call, got {states}")
    if "accepted" in states or "ignored" in states:
        raise SystemExit(
            f"Axoloty must never observe the late Return at all (no active subscription), got {states}"
        )
    if states.index("gave-up") >= states.index("done"):
        raise SystemExit(f"Expected 'gave-up' to precede 'done', got {states}")

    # The actual "late" cross-check: the wire RTN's broker-side capture
    # timestamp must fall after the moment the Axoloty subject reported
    # giving up (which is when its correlated response subscription is
    # released). Without this comparison, a regression that made CoatyJS
    # reply early for an unrelated reason would still pass. The capture's
    # `capturedAt` has whole-second resolution (see mqtt_capture.py), so its
    # true instant may be up to 1s later than the parsed value; requiring
    # the floored capture time to be >= the gave-up time therefore never
    # produces a false failure and still rejects any Return that arrived
    # before the subject gave up.
    gave_up = next(r for r in application_log if r["state"] == "gave-up")
    if "at" not in gave_up:
        raise SystemExit(
            "The application log's gave-up record carries no 'at' timestamp; "
            "cannot prove the Return arrived late"
        )
    gave_up_at = parse_utc(gave_up["at"])
    return_at = parse_utc(return_records[0]["capturedAt"])
    if return_at < gave_up_at:
        raise SystemExit(
            f"The wire RTN was captured at {return_at.isoformat()} but Axoloty "
            f"only gave up at {gave_up_at.isoformat()}: the Return was not "
            "late relative to the subject's timeout, so this run does not "
            "demonstrate the late-reply scenario"
        )


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
