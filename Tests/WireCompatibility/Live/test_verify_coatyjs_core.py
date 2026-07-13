#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Regression tests for exact CoatyJS core capture topic validation."""

import copy
import base64
import importlib.util
import json
import pathlib
import unittest


HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "verify_coatyjs_core", HERE / "verify-coatyjs-core.py"
)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class ExactTopicValidationTests(unittest.TestCase):
    def record(self, topic, value):
        payload = base64.b64encode(json.dumps(value).encode("utf-8")).decode("ascii")
        return {
            "mqtt": {"topic": topic, "qos": 0, "retain": False},
            "payload": {"bytes": payload},
        }

    def capture(self, scenario):
        requester = "22222222-2222-4222-8222-222222222222"
        responder = "33333333-3333-4333-8333-333333333333"
        correlation = "55555555-5555-4555-8555-555555555555"
        root = "coaty/3/wire-compat-v1"
        if scenario == "channel":
            return [self.record(
                f"{root}/CHN:wire-fixture-channel/{requester}",
                {"objectId": VERIFIER.OBJECT_ID,
                 "privateData": {"sequence": 7, "reference": "coatyjs-2.4.0"}},
            )]
        if scenario == "discover-resolve":
            return [
                self.record(
                    f"{root}/DSC/{requester}/{correlation}",
                    {"objectType": VERIFIER.OBJECT_TYPE},
                ),
                self.record(
                    f"{root}/RSV/{responder}/{correlation}",
                    {"object": {"objectId": VERIFIER.OBJECT_ID},
                     "privateData": {"reference": "coatyjs-2.4.0"}},
                ),
            ]
        raise ValueError(f"unsupported test scenario: {scenario}")

    def test_channel_rejects_an_extra_topic_level(self):
        capture = copy.deepcopy(self.capture("channel"))
        channel = next(
            record for record in capture
            if "/CHN:wire-fixture-channel/" in record["mqtt"]["topic"]
        )
        channel["mqtt"]["topic"] += "/unexpected"

        with self.assertRaisesRegex(AssertionError, "expected one deterministic Channel"):
            VERIFIER.verify_channel(capture)

    def test_discover_rejects_an_invalid_source_uuid(self):
        capture = copy.deepcopy(self.capture("discover-resolve"))
        discover = next(
            record for record in capture if "/DSC/" in record["mqtt"]["topic"]
        )
        levels = discover["mqtt"]["topic"].split("/")
        levels[-2] = "not-a-uuid"
        discover["mqtt"]["topic"] = "/".join(levels)

        with self.assertRaisesRegex(AssertionError, "expected one deterministic Discover"):
            VERIFIER.verify_discover_resolve(capture)

    def test_discover_rejects_an_invalid_correlation_uuid(self):
        capture = copy.deepcopy(self.capture("discover-resolve"))
        for record in capture:
            if "/DSC/" in record["mqtt"]["topic"] or "/RSV/" in record["mqtt"]["topic"]:
                levels = record["mqtt"]["topic"].split("/")
                levels[-1] = "not-a-uuid"
                record["mqtt"]["topic"] = "/".join(levels)

        with self.assertRaisesRegex(AssertionError, "expected one deterministic Discover"):
            VERIFIER.verify_discover_resolve(capture)

    def test_discover_rejects_a_wrong_valid_requester_uuid(self):
        capture = copy.deepcopy(self.capture("discover-resolve"))
        discover = next(
            record for record in capture if "/DSC/" in record["mqtt"]["topic"]
        )
        levels = discover["mqtt"]["topic"].split("/")
        levels[-2] = "44444444-4444-4444-8444-444444444444"
        discover["mqtt"]["topic"] = "/".join(levels)

        with self.assertRaisesRegex(AssertionError, "expected one deterministic Discover"):
            VERIFIER.verify_discover_resolve(capture)

    def test_resolve_rejects_a_wrong_valid_responder_uuid(self):
        capture = copy.deepcopy(self.capture("discover-resolve"))
        resolve = next(
            record for record in capture if "/RSV/" in record["mqtt"]["topic"]
        )
        levels = resolve["mqtt"]["topic"].split("/")
        levels[-2] = "44444444-4444-4444-8444-444444444444"
        resolve["mqtt"]["topic"] = "/".join(levels)

        with self.assertRaisesRegex(AssertionError, "expected one correlated deterministic Resolve"):
            VERIFIER.verify_discover_resolve(capture)


if __name__ == "__main__":
    unittest.main()
