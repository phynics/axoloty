#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Verify the semantic and topic contract of the pinned CoatyJS Advertise run."""

import argparse
import base64
import json
import sys


EXPECTED_OBJECT = {
    "coreType": "CoatyObject",
    "objectType": "com.coaty.test.WireFixture",
    "objectId": "11111111-1111-4111-8111-111111111111",
    "name": "wire-fixture",
}


def load_records(path):
    with open(path, encoding="utf-8") as capture:
        return [json.loads(line) for line in capture if line.strip()]


def decode_payload(record):
    raw = base64.b64decode(record["payload"]["bytes"], validate=True)
    return json.loads(raw.decode("utf-8"))


def advertised_object(payload):
    if isinstance(payload, dict):
        if all(payload.get(key) == value for key, value in EXPECTED_OBJECT.items()):
            return payload
        for value in payload.values():
            found = advertised_object(value)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for value in payload:
            found = advertised_object(value)
            if found is not None:
                return found
    return None


def verify(path):
    records = load_records(path)
    matching = []
    for record in records:
        try:
            payload = decode_payload(record)
        except (KeyError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise AssertionError(f"invalid capture record: {error}") from error
        if advertised_object(payload) is not None:
            matching.append(record)

    if not matching:
        raise AssertionError("no Advertise payload contained the deterministic fixture object")

    topics = {record["mqtt"]["topic"] for record in matching}
    expected_prefixes = (
        "coaty/3/wire-compat-v1/ADV:CoatyObject/",
        "coaty/3/wire-compat-v1/ADV::com.coaty.test.WireFixture/",
    )
    missing = [prefix for prefix in expected_prefixes if not any(topic.startswith(prefix) for topic in topics)]
    if missing:
        raise AssertionError(f"missing expected Advertise topic variant(s): {', '.join(missing)}; got {sorted(topics)}")

    for record in matching:
        mqtt = record["mqtt"]
        if mqtt["retain"] or mqtt["qos"] != 0:
            raise AssertionError(f"unexpected MQTT flags on {mqtt['topic']}: qos={mqtt['qos']} retain={mqtt['retain']}")

    print(f"PASS: CoatyJS Advertise semantic contract ({len(matching)} matching publications)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture")
    args = parser.parse_args()
    try:
        verify(args.capture)
    except (OSError, AssertionError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
