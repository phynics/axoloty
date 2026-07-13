#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Verify pinned CoatyJS core event captures."""

import argparse
import base64
import json
import sys
import uuid


OBJECT_ID = "11111111-1111-4111-8111-111111111111"
OBJECT_TYPE = "com.coaty.test.WireFixture"
TOPIC_NAMESPACE = "wire-compat-v1"
REQUESTER_ID = "22222222-2222-4222-8222-222222222222"
RESPONDER_ID = "33333333-3333-4333-8333-333333333333"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def records(path):
    with open(path, encoding="utf-8") as capture:
        return [json.loads(line) for line in capture if line.strip()]


def decoded(record):
    raw = base64.b64decode(record["payload"]["bytes"], validate=True)
    return json.loads(raw.decode("utf-8"))


def contains(value, predicate):
    if predicate(value):
        return True
    if isinstance(value, dict):
        return any(contains(item, predicate) for item in value.values())
    if isinstance(value, list):
        return any(contains(item, predicate) for item in value)
    return False


def assert_flags(record):
    mqtt = record["mqtt"]
    require(mqtt["qos"] == 0 and not mqtt["retain"], (
        f"unexpected MQTT flags on {mqtt['topic']}: "
        f"qos={mqtt['qos']} retain={mqtt['retain']}"
    ))


def canonical_uuid(value):
    try:
        return str(uuid.UUID(value)) == value
    except (AttributeError, ValueError):
        return False


def topic_correlation(topic, event, source_id, correlated=False):
    levels = topic.split("/")
    expected_count = 6 if correlated else 5
    if len(levels) != expected_count:
        return None
    if levels[:4] != ["coaty", "3", TOPIC_NAMESPACE, event]:
        return None
    if not canonical_uuid(levels[4]) or levels[4] != source_id:
        return None
    if correlated and not canonical_uuid(levels[5]):
        return None
    return levels[5] if correlated else ""


def verify_deadvertise(capture):
    matches = [
        record for record in capture
        if topic_correlation(record["mqtt"]["topic"], "DAD", REQUESTER_ID) is not None
        and contains(decoded(record), lambda value: value == OBJECT_ID)
    ]
    require(len(matches) == 1, f"expected one deterministic Deadvertise, got {len(matches)}")
    assert_flags(matches[0])


def verify_channel(capture):
    matches = [
        record for record in capture
        if topic_correlation(
            record["mqtt"]["topic"], "CHN:wire-fixture-channel", REQUESTER_ID
        ) is not None
        and contains(decoded(record), lambda value: value == OBJECT_ID)
        and contains(decoded(record), lambda value: value == {"sequence": 7, "reference": "coatyjs-2.4.0"})
    ]
    require(len(matches) == 1, f"expected one deterministic Channel event, got {len(matches)}")
    assert_flags(matches[0])


def verify_discover_resolve(capture):
    discovers = [
        record for record in capture
        if topic_correlation(
            record["mqtt"]["topic"], "DSC", REQUESTER_ID, correlated=True
        ) is not None
        and contains(decoded(record), lambda value: value == OBJECT_TYPE)
    ]
    require(len(discovers) == 1, f"expected one deterministic Discover, got {len(discovers)}")
    discover_id = topic_correlation(
        discovers[0]["mqtt"]["topic"], "DSC", REQUESTER_ID, correlated=True
    )

    resolves = [
        record for record in capture
        if topic_correlation(
            record["mqtt"]["topic"], "RSV", RESPONDER_ID, correlated=True
        ) == discover_id
        and contains(decoded(record), lambda value: value == OBJECT_ID)
        and contains(decoded(record), lambda value: value == {"reference": "coatyjs-2.4.0"})
    ]
    require(len(resolves) == 1, (
        f"expected one correlated deterministic Resolve for {discover_id}, got {len(resolves)}"
    ))
    assert_flags(discovers[0])
    assert_flags(resolves[0])


def verify_pair(capture, request_prefix, response_prefix, request_values, response_values):
    requests = [
        record for record in capture
        if topic_correlation(
            record["mqtt"]["topic"], request_prefix.rstrip("/"),
            REQUESTER_ID, correlated=True
        ) is not None
        and all(contains(decoded(record), lambda item, value=value: item == value)
                for value in request_values)
    ]
    require(len(requests) == 1, f"expected one deterministic {request_prefix}, got {len(requests)}")
    request_id = topic_correlation(
        requests[0]["mqtt"]["topic"], request_prefix.rstrip("/"),
        REQUESTER_ID, correlated=True
    )
    responses = [
        record for record in capture
        if topic_correlation(
            record["mqtt"]["topic"], response_prefix.rstrip("/"),
            RESPONDER_ID, correlated=True
        ) == request_id
        and all(contains(decoded(record), lambda item, value=value: item == value)
                for value in response_values)
    ]
    require(len(responses) == 1, (
        f"expected one correlated deterministic {response_prefix} for {request_id}, "
        f"got {len(responses)}"
    ))
    assert_flags(requests[0])
    assert_flags(responses[0])


def verify_query_retrieve(capture):
    verify_pair(
        capture, "QRY/", "RTV/", [OBJECT_TYPE],
        [OBJECT_ID, {"reference": "coatyjs-2.4.0", "resultSet": "deterministic"}]
    )


def verify_update_complete(capture):
    concrete_topic = "UPD::" + OBJECT_TYPE + "/"
    verify_pair(
        capture, concrete_topic, "CPL/", [OBJECT_ID, "wire-fixture"],
        [OBJECT_ID, "wire-fixture-completed", {"reference": "coatyjs-2.4.0"}]
    )
    supertype_updates = [
        record for record in capture
        if topic_correlation(
            record["mqtt"]["topic"], "UPD:CoatyObject", REQUESTER_ID,
            correlated=True
        ) is not None
        and contains(decoded(record), lambda value: value == OBJECT_ID)
        and contains(decoded(record), lambda value: value == "wire-fixture")
    ]
    require(len(supertype_updates) == 1, (
        "expected one deterministic CoatyObject-routed Update, "
        f"got {len(supertype_updates)}"
    ))
    assert_flags(supertype_updates[0])


def verify_call_return(capture):
    verify_pair(
        capture, "CLL:wire-fixture-operation/", "RTN/",
        [{"operand": 7, "reference": "coatyjs-2.4.0"}],
        [{"answer": 49, "objectId": OBJECT_ID}, {"executor": "coatyjs-2.4.0"}]
    )


VERIFY = {
    "deadvertise": verify_deadvertise,
    "channel": verify_channel,
    "discover-resolve": verify_discover_resolve,
    "query-retrieve": verify_query_retrieve,
    "update-complete": verify_update_complete,
    "call-return": verify_call_return,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=VERIFY)
    parser.add_argument("capture")
    args = parser.parse_args()
    try:
        VERIFY[args.scenario](records(args.capture))
    except (OSError, KeyError, ValueError, UnicodeDecodeError, json.JSONDecodeError, AssertionError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: CoatyJS {args.scenario} wire contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
