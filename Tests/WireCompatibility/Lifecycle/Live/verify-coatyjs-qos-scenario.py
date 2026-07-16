#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Verify the semantic contract for the qos-0/graceful-deadvertise lifecycle scenarios."""

import argparse
import base64
import json
import sys


def load_records(path):
    with open(path, encoding="utf-8") as capture:
        return [json.loads(line) for line in capture if line.strip()]


def decode_payload(record):
    raw = base64.b64decode(record["payload"]["bytes"], validate=True)
    return json.loads(raw.decode("utf-8"))


def verify_qos(records, expected_qos, object_id):
    matching = []
    for record in records:
        if not record["mqtt"]["topic"].startswith("coaty/3/"):
            continue
        try:
            payload = decode_payload(record)
        except (KeyError, ValueError, UnicodeDecodeError, json.JSONDecodeError):
            continue
        obj = payload.get("object") if isinstance(payload, dict) else None
        if isinstance(obj, dict) and obj.get("objectId") == object_id:
            matching.append(record)
    if not matching:
        raise AssertionError(f"no publication of object {object_id} was observed")
    for record in matching:
        if record["mqtt"]["qos"] != expected_qos:
            raise AssertionError(
                f"expected QoS {expected_qos} on {record['mqtt']['topic']}, got {record['mqtt']['qos']}"
            )
    print(f"PASS: observed {len(matching)} publication(s) of {object_id} at QoS {expected_qos}")


def verify_graceful_deadvertise(records, identity_id):
    advertised = [
        r for r in records
        if "/ADV:Identity/" in r["mqtt"]["topic"] and identity_id in r["mqtt"]["topic"]
    ]
    deadvertised = [
        r for r in records
        if "/DAD/" in r["mqtt"]["topic"] and identity_id in r["mqtt"]["topic"]
    ]
    if not advertised:
        raise AssertionError("identity advertisement was not observed")
    if not deadvertised:
        raise AssertionError("graceful Deadvertise was not observed")
    if min(r["sequence"] for r in deadvertised) <= min(r["sequence"] for r in advertised):
        raise AssertionError("Deadvertise preceded its Advertise")
    for record in advertised + deadvertised:
        mqtt = record["mqtt"]
        if mqtt["retain"] or mqtt["qos"] != 0:
            raise AssertionError(f"unexpected MQTT flags on {mqtt['topic']}: qos={mqtt['qos']} retain={mqtt['retain']}")
    print(f"PASS: graceful Deadvertise observed after Advertise ({len(advertised)} ADV, {len(deadvertised)} DAD)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=("qos-0", "graceful-deadvertise"))
    parser.add_argument("capture")
    parser.add_argument("--object-id")
    parser.add_argument("--identity-id")
    args = parser.parse_args()
    try:
        records = load_records(args.capture)
        if args.scenario == "qos-0":
            verify_qos(records, 0, args.object_id)
        else:
            verify_graceful_deadvertise(records, args.identity_id)
    except (OSError, AssertionError, KeyError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
