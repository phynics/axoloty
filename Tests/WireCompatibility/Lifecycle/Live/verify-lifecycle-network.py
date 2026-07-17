#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Verify the network-failure lifecycle scenarios against retained evidence.

Each verifier cross-checks the Axoloty subject's application log (JSONL
state lines with UTC timestamps), the independent MQTT capture (which
connects to the broker directly, bypassing the severed proxy), and -- for
clean-session -- the proxy's decoded CONNACK log. Nothing here re-runs a
scenario; a failed check exits nonzero so the orchestrating script fails
even though the subject process exited 0.
"""

import argparse
import base64
import json
from pathlib import Path


def load_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def states(application_log):
    return [record["state"] for record in application_log]


def require_state_order(application_log, expected):
    """The subject must have reported exactly these states, in this order."""
    got = states(application_log)
    if got != expected:
        raise SystemExit(f"Expected subject states {expected}, got {got}")


def advertised_names(capture, object_type):
    """Decoded names of Advertise payloads for one object type, in wire order.

    Only the object-type route (``ADV::<objectType>``) is counted: a Coaty
    Advertise for a custom object type is legitimately published on both the
    core-type and the object-type route, so counting both would misread the
    protocol's dual routing as duplicate delivery.
    """
    names = []
    for record in capture:
        topic = record["mqtt"]["topic"]
        if f"/ADV::{object_type}/" not in topic:
            continue
        try:
            payload = json.loads(base64.b64decode(record["payload"]["bytes"]))
        except (ValueError, KeyError):
            continue
        obj = payload.get("object", {})
        if obj.get("objectType") == object_type:
            names.append(obj.get("name"))
    return names


def verify_offline_queueing(capture, application_log, connack_log=None):
    require_state_order(
        application_log, ["ready", "offline", "published-offline", "reconnected", "done"]
    )
    names = advertised_names(capture, "com.coaty.test.WireQueuedFixture")
    if names != ["first", "second"]:
        raise SystemExit(
            "Expected the queued publications to arrive in order exactly once "
            f"(['first', 'second']), got {names}"
        )


def verify_probe_scenario(scenario, capture, application_log):
    require_state_order(
        application_log, ["ready", "offline", "reconnected", "probe-received", "done"]
    )
    probe_record = next(
        (r for r in application_log if r["state"] == "probe-received"), None
    )
    if probe_record.get("name") != "wire-fixture":
        raise SystemExit(
            f"Expected the subject to decode the CoatyJS probe by name, got {probe_record}"
        )
    names = advertised_names(capture, "com.coaty.test.WireFixture")
    if names.count("wire-fixture") < 1:
        raise SystemExit(
            f"Expected the CoatyJS probe Advertise on the wire, capture has {names}"
        )


def verify_reconnect_resubscribe(capture, application_log, connack_log=None):
    verify_probe_scenario("reconnect-resubscribe", capture, application_log)


def verify_broker_restart(capture, application_log, connack_log=None):
    verify_probe_scenario("broker-restart", capture, application_log)


def verify_clean_session(capture, application_log, connack_log=None):
    verify_probe_scenario("clean-session", capture, application_log)
    if connack_log is None:
        raise SystemExit("clean-session requires the proxy CONNACK log")
    connacks = load_jsonl(connack_log)
    if len(connacks) < 2:
        raise SystemExit(
            "Expected at least two decoded CONNACKs through the proxy "
            f"(initial connect and reconnect), got {len(connacks)}"
        )
    stale = [c for c in connacks if c.get("sessionPresent") is not False]
    if stale:
        raise SystemExit(
            "Expected every CONNACK to report sessionPresent=false (Axoloty "
            f"connects with cleanSession: true), got {stale}"
        )


VERIFIERS = {
    "offline-queueing": verify_offline_queueing,
    "reconnect-resubscribe": verify_reconnect_resubscribe,
    "broker-restart": verify_broker_restart,
    "clean-session": verify_clean_session,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=sorted(VERIFIERS))
    parser.add_argument("capture", type=Path)
    parser.add_argument("application_log", type=Path)
    parser.add_argument("--connack-log", type=Path)
    args = parser.parse_args()
    capture = load_jsonl(args.capture)
    application_log = load_jsonl(args.application_log)
    VERIFIERS[args.scenario](capture, application_log, connack_log=args.connack_log)
    print(
        f"OK: {args.scenario} verified against {len(capture)} wire records "
        f"and {len(application_log)} app states"
    )


if __name__ == "__main__":
    main()
