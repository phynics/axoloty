#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Verify identity advertisement followed by the broker-issued last will."""
import argparse
import base64
import json
import sys

IDENTITY_ID = "33333333-3333-4333-8333-333333333333"

def verify(path):
    with open(path, encoding="utf-8") as source:
        records = [json.loads(line) for line in source if line.strip()]
    matching = []
    for record in records:
        payload = base64.b64decode(record["payload"]["bytes"], validate=True).decode("utf-8")
        if IDENTITY_ID in payload or IDENTITY_ID in record["mqtt"]["topic"]:
            matching.append(record)
    advertised = [r for r in matching if "/ADV:" in r["mqtt"]["topic"]]
    deadvertised = [r for r in matching if "/DAD/" in r["mqtt"]["topic"]]
    if not advertised:
        raise AssertionError("identity advertisement was not observed")
    if not deadvertised:
        raise AssertionError("identity last will was not observed after SIGKILL")
    if min(r["sequence"] for r in deadvertised) <= min(r["sequence"] for r in advertised):
        raise AssertionError("identity last will preceded its advertisement")
    for record in advertised + deadvertised:
        mqtt = record["mqtt"]
        if mqtt["retain"] or mqtt["qos"] != 0:
            raise AssertionError(f"unexpected MQTT flags on {mqtt['topic']}")
    print(f"PASS: CoatyJS last will ({len(advertised)} advertise, {len(deadvertised)} deadvertise)")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture")
    try:
        verify(parser.parse_args().capture)
    except (OSError, ValueError, UnicodeDecodeError, json.JSONDecodeError, AssertionError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
