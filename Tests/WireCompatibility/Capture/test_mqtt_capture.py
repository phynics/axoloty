#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import base64
from pathlib import Path
import tempfile
import unittest

import mqtt_capture


class CaptureFormatTests(unittest.TestCase):
    def test_ready_marker_is_atomically_created_after_subscription(self):
        with tempfile.TemporaryDirectory() as directory:
            ready_file = Path(directory) / "capture.ready"

            mqtt_capture.mark_ready(str(ready_file))

            self.assertEqual(ready_file.read_text(encoding="utf-8"), "subscribed\n")
            self.assertEqual(list(ready_file.parent.glob(".*.tmp")), [])

    def test_publish_parser_preserves_wire_metadata_and_bytes(self):
        topic = b"coaty/ns/advertise"
        payload = b'{"value":1}\x00'
        body = len(topic).to_bytes(2, "big") + topic + b"\x12\x34" + payload

        message = mqtt_capture.parse_publish(0x3b, body)

        self.assertEqual(message["topic"], topic.decode())
        self.assertEqual(message["payload"], payload)
        self.assertEqual(message["qos"], 1)
        self.assertTrue(message["retain"])
        self.assertTrue(message["duplicate"])
        self.assertEqual(message["packet_id"], 0x1234)

    def test_capture_record_contains_provenance_and_lossless_payload(self):
        message = {
            "topic": "coaty/ns/advertise",
            "payload": b"\xff\x00wire",
            "qos": 0,
            "retain": False,
            "duplicate": False,
            "packet_id": None,
        }
        metadata = {
            "producer": "coatyjs",
            "producer_version": "2.0.0",
            "scenario": "advertise",
            "normalization_profile": "coaty-v1",
        }

        record = mqtt_capture.capture_record(message, metadata, 7)

        self.assertEqual(record["format"], "coaty-wire-capture/v1")
        self.assertEqual(record["producer"], {"implementation": "coatyjs", "version": "2.0.0"})
        self.assertEqual(record["scenario"], "advertise")
        self.assertEqual(record["sequence"], 7)
        self.assertEqual(record["mqtt"]["topic"], message["topic"])
        self.assertEqual(base64.b64decode(record["payload"]["bytes"]), message["payload"])


if __name__ == "__main__":
    unittest.main()
