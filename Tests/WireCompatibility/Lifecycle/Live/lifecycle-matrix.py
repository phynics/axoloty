#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Create provenance manifests for the live lifecycle compatibility matrix."""

import argparse
import hashlib
import json
from pathlib import Path


# An ``unsupported`` disposition is deliberate evidence of a reference-agent
# or harness boundary, not a skipped passing scenario.
_QOS_BINDING_LIMITATION = (
    "Pinned @coaty/core 2.4.0's MqttBinding hardcodes QoS 0 for every publish "
    "(see mqtt-binding.js's onJoin, which sets this._qos = 0 unconditionally) "
    "and never reads any QoS option back out of communication configuration, "
    "confirmed empirically: a live attempt at this scenario captured a "
    "PUBLISH with qos 0 despite requesting a higher level. There is no "
    "alternative live QoS producer in this harness."
)

SCENARIOS = {}
SCENARIOS["offline-queueing"] = {
    "id": "offline-queueing",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Axoloty is the live subject behind tcp_proxy.py: with its TCP path "
        "to the broker genuinely severed, it publishes two labeled Advertise "
        "events (CommunicationManager.publish defers them while offline), "
        "and after the path is restored the independent capture -- which "
        "bypasses the proxy -- proves both arrive in order exactly once on "
        "the object-type route."
    ),
}
SCENARIOS["reconnect-resubscribe"] = {
    "id": "reconnect-resubscribe",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Axoloty is the live subject behind tcp_proxy.py; after a real TCP "
        "sever and restore it must decode an Advertise probe published by "
        "pinned CoatyJS 2.4.0 only after the subject reported its reconnect. "
        "Since Axoloty always connects with cleanSession: true, receiving "
        "the probe proves the SubscriptionCoordinator genuinely re-subscribed "
        "on the new connection."
    ),
}
SCENARIOS["broker-restart"] = {
    "id": "broker-restart",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Axoloty is the live subject against a Mosquitto process that is "
        "really stopped and restarted; the subject must reconnect and decode "
        "a post-restart CoatyJS 2.4.0 Advertise probe. This scenario "
        "initially failed and exposed a real defect: MQTTNIOClient's failed "
        "connect attempts never rescheduled auto-reconnect (only established-"
        "then-closed connections did), fixed alongside this harness."
    ),
}
SCENARIOS["clean-session"] = {
    "id": "clean-session",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Same live sever/restore cycle as reconnect-resubscribe, plus "
        "tcp_proxy.py decodes every MQTT CONNACK on the subject's connection "
        "and the verifier requires at least two handshakes, all reporting "
        "sessionPresent=false -- the broker's own confirmation that Axoloty's "
        "hardcoded cleanSession: true left no session state behind."
    ),
}
SCENARIOS["qos-1"] = {
    "id": "qos-1",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "unsupported",
    "reason": _QOS_BINDING_LIMITATION,
}
SCENARIOS["qos-2"] = {
    "id": "qos-2",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "unsupported",
    "reason": _QOS_BINDING_LIMITATION,
}
SCENARIOS["duplicate-reply"] = {
    "id": "duplicate-reply",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Axoloty is the live Call/Return initiator; pinned CoatyJS 2.4.0 is a "
        "real responder that sends two genuine wire Return publishes "
        "(original then duplicate, 300ms apart) for the same correlationId "
        "-- nothing in @coaty/core 2.4.0's CallEvent.returnEvent prevents "
        "this, confirmed by reading call-return.js and "
        "communication-manager.js before writing the responder. Axoloty's "
        "EventHub does not deduplicate Return events by correlationId "
        "either; the application-level 'accept only the first' behavior "
        "asserted here is real caller logic, not a library guarantee."
    ),
}
SCENARIOS["late-reply"] = {
    "id": "late-reply",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Axoloty is the live Call/Return initiator with a real 2s response "
        "deadline; pinned CoatyJS 2.4.0 deliberately withholds its Return "
        "until 4s (past that deadline) before genuinely publishing it. The "
        "independent MQTT capture proves the late Return actually reached "
        "the broker after Axoloty's CM+Publish.swift responseStream had "
        "already released (unsubscribed) the correlated response topic on "
        "timeout, so the late reply is provably unobservable, not merely "
        "unobserved."
    ),
}
SCENARIOS["unexpected-disconnect-last-will"] = {
    "id": "unexpected-disconnect-last-will",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Pinned CoatyJS 2.4.0 is a real subject; a passive MQTT probe verifies "
        "its advertised identity and broker-issued last will. Axoloty is recorded "
        "as an unavailable subject, not as cross-implementation proof."
    ),
}
SCENARIOS["qos-0"] = {
    "id": "qos-0",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Pinned CoatyJS 2.4.0 publishes a deterministic object at QoS 0 (its "
        "only supported level, see the qos-1/qos-2 reason above); a passive "
        "MQTT probe verifies the wire QoS. Axoloty is recorded as an "
        "unavailable subject, not as cross-implementation proof."
    ),
}
SCENARIOS["graceful-deadvertise"] = {
    "id": "graceful-deadvertise",
    "participants": ["axoloty", "coatyjs-2.4.0"],
    "status": "executable",
    "reason": (
        "Pinned CoatyJS 2.4.0 calls container.shutdown() itself (not SIGKILL) "
        "and a passive MQTT probe verifies the client-issued Deadvertise "
        "follows its Advertise, distinct from the broker-issued last will "
        "covered by unexpected-disconnect-last-will. Axoloty is recorded as "
        "an unavailable subject, not as cross-implementation proof."
    ),
}


def artifact(path, require_json_lines=False):
    """Return immutable metadata for a nonempty retained evidence artifact."""
    path = Path(path)
    if not path.is_file() or not path.read_bytes():
        raise ValueError(f"required evidence is missing or empty: {path}")
    content = path.read_bytes()
    if require_json_lines:
        lines = [line for line in content.decode("utf-8").splitlines() if line.strip()]
        if not lines:
            raise ValueError(f"required capture has no records: {path}")
        for line in lines:
            json.loads(line)
    else:
        lines = None
    result = {"path": path.name, "sha256": hashlib.sha256(content).hexdigest()}
    if lines is not None:
        result["records"] = len(lines)
    return result


def evidence_manifest(scenario, application_log, capture):
    """Return an executed manifest only when both application and wire agree."""
    if scenario["status"] != "executable":
        raise ValueError(f"{scenario['id']} is not executable")
    if not Path(capture).is_file():
        raise ValueError(f"required capture is missing: {capture}")
    return {
        "format": "axoloty-lifecycle-evidence/v1",
        "scenario": scenario["id"],
        "status": "executed",
        "limitation": scenario["reason"],
        "evidence": {
            "applicationLog": artifact(application_log, require_json_lines=True),
            "capture": artifact(capture, require_json_lines=True),
        },
    }


def unsupported_manifest(scenario):
    """Return a non-passing manifest for a documented execution limitation."""
    if scenario["status"] != "unsupported":
        raise ValueError(f"{scenario['id']} is executable")
    return {
        "format": "axoloty-lifecycle-evidence/v1",
        "scenario": scenario["id"],
        "status": "unsupported",
        "limitation": scenario["reason"],
        "participants": scenario["participants"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=sorted(SCENARIOS))
    parser.add_argument("--application-log", type=Path)
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    scenario = SCENARIOS[args.scenario]
    if scenario["status"] == "executable":
        if args.application_log is None or args.capture is None:
            parser.error("executable scenarios require --application-log and --capture")
        manifest = evidence_manifest(scenario, args.application_log, args.capture)
    else:
        manifest = unsupported_manifest(scenario)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
