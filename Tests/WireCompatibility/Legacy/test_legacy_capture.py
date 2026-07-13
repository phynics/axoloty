#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import base64
import hashlib
import json
import pathlib
import tempfile
import unittest

from validate_legacy_capture import ValidationError, validate


class LegacyCaptureValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temporary.name)
        self.capture = self.directory / "advertise.jsonl"
        record = {
            "format": "coaty-wire-capture/v1",
            "producer": {"implementation": "coatyswift-legacy", "version": "2.4.0"},
            "scenario": "advertise",
            "sequence": 1,
            "capturedAt": "2026-07-13T00:00:00Z",
            "mqtt": {"topic": "coaty/test/ADV", "qos": 0, "retain": False, "duplicate": False},
            "payload": {"encoding": "base64", "bytes": base64.b64encode(b'{"name":"legacy"}').decode()},
            "normalizationProfile": "coaty-v1",
        }
        self.capture.write_text(json.dumps(record, separators=(",", ":")) + "\n")
        self.manifest = self.directory / "advertise.manifest.json"
        self.write_manifest()

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self):
        value = {
            "format": "coaty-legacy-capture-manifest/v1",
            "capture": {
                "file": self.capture.name,
                "sha256": hashlib.sha256(self.capture.read_bytes()).hexdigest(),
                "recordCount": 1,
            },
            "producer": {"implementation": "coatyswift-legacy", "version": "2.4.0"},
            "source": {
                "repository": "https://github.com/coatyio/coaty-swift.git",
                "commit": "20a97b29832758fb771ac79fd5f7ae36cff69403",
            },
            "runner": {
                "os": "macOS", "architecture": "arm64", "swiftVersion": "Swift 5.9",
                "xcodeVersion": "Xcode 15", "generatedAt": "2026-07-13T00:00:00+00:00",
            },
            "scenario": "advertise",
        }
        self.manifest.write_text(json.dumps(value) + "\n")

    def test_accepts_provenance_bound_capture(self):
        self.assertEqual(validate(self.capture, self.manifest), 1)

    def test_rejects_modified_capture(self):
        self.capture.write_text(self.capture.read_text().replace("2026-07-13", "2026-07-14"))
        with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
            validate(self.capture, self.manifest)

    def test_rejects_linux_provenance_even_with_matching_digest(self):
        value = json.loads(self.manifest.read_text())
        value["runner"]["os"] = "Linux"
        self.manifest.write_text(json.dumps(value) + "\n")
        with self.assertRaisesRegex(ValidationError, "generated on macOS"):
            validate(self.capture, self.manifest)

    def test_rejects_non_legacy_producer(self):
        value = json.loads(self.manifest.read_text())
        value["producer"]["implementation"] = "coatyswift-modern"
        self.manifest.write_text(json.dumps(value) + "\n")
        with self.assertRaisesRegex(ValidationError, "not legacy"):
            validate(self.capture, self.manifest)

    def test_rejects_unpinned_legacy_version(self):
        value = json.loads(self.manifest.read_text())
        value["producer"]["version"] = "2.4.1"
        self.manifest.write_text(json.dumps(value) + "\n")
        with self.assertRaisesRegex(ValidationError, "pinned to 2.4.0"):
            validate(self.capture, self.manifest)

    def test_rejects_unpinned_source_commit(self):
        value = json.loads(self.manifest.read_text())
        value["source"]["commit"] = "0" * 40
        self.manifest.write_text(json.dumps(value) + "\n")
        with self.assertRaisesRegex(ValidationError, "pinned legacy"):
            validate(self.capture, self.manifest)

    def test_rejects_invalid_payload_even_when_manifest_is_updated(self):
        record = json.loads(self.capture.read_text())
        record["payload"]["bytes"] = "not base64"
        self.capture.write_text(json.dumps(record) + "\n")
        self.write_manifest()
        with self.assertRaisesRegex(ValidationError, "invalid base64"):
            validate(self.capture, self.manifest)


if __name__ == "__main__":
    unittest.main()
