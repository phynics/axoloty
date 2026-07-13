#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Validate a legacy CoatySwift capture and its provenance manifest."""

import argparse
import base64
import hashlib
import json
import pathlib
import re
import sys

FORMAT = "coaty-wire-capture/v1"
MANIFEST_FORMAT = "coaty-legacy-capture-manifest/v1"
LEGACY_IMPLEMENTATION = "coatyswift-legacy"
LEGACY_VERSION = "2.4.0"
LEGACY_SOURCE_COMMIT = "20a97b29832758fb771ac79fd5f7ae36cff69403"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SOURCE_COMMIT = re.compile(r"^[0-9a-f]{40}$")


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def require_exact_keys(value, required, optional, context):
    require(isinstance(value, dict), f"{context} must be an object")
    missing = required - value.keys()
    unknown = value.keys() - required - optional
    require(not missing, f"{context} missing keys: {sorted(missing)}")
    require(not unknown, f"{context} has unknown keys: {sorted(unknown)}")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"cannot read manifest: {error}") from error
    required = {"format", "capture", "producer", "source", "runner", "scenario"}
    require_exact_keys(value, required, set(), "manifest")
    require(value["format"] == MANIFEST_FORMAT, "unsupported manifest format")

    capture = value["capture"]
    require_exact_keys(capture, {"file", "sha256", "recordCount"}, set(), "manifest.capture")
    require(isinstance(capture["file"], str) and pathlib.PurePath(capture["file"]).name == capture["file"],
            "manifest.capture.file must be a basename")
    require(isinstance(capture["sha256"], str) and SHA256.fullmatch(capture["sha256"]),
            "manifest.capture.sha256 must be lowercase SHA-256")
    require(isinstance(capture["recordCount"], int) and capture["recordCount"] > 0,
            "manifest.capture.recordCount must be positive")

    producer = value["producer"]
    require_exact_keys(producer, {"implementation", "version"}, set(), "manifest.producer")
    require(producer["implementation"] == LEGACY_IMPLEMENTATION,
            "manifest producer is not legacy CoatySwift")
    require(producer["version"] == LEGACY_VERSION,
            f"producer version must be pinned to {LEGACY_VERSION}")

    source = value["source"]
    require_exact_keys(source, {"repository", "commit"}, set(), "manifest.source")
    require(isinstance(source["repository"], str) and source["repository"].startswith("https://"),
            "source repository must be HTTPS")
    require(isinstance(source["commit"], str) and SOURCE_COMMIT.fullmatch(source["commit"]),
            "source commit must be a full lowercase Git SHA")
    require(source["commit"] == LEGACY_SOURCE_COMMIT,
            "source commit does not match the pinned legacy CoatySwift oracle")

    runner = value["runner"]
    require_exact_keys(runner, {"os", "architecture", "swiftVersion", "xcodeVersion", "generatedAt"},
                       set(), "manifest.runner")
    require(runner["os"] == "macOS", "legacy captures must be generated on macOS")
    for key in ("architecture", "swiftVersion", "xcodeVersion", "generatedAt"):
        require(isinstance(runner[key], str) and runner[key], f"runner.{key} is empty")
    require(isinstance(value["scenario"], str) and value["scenario"], "scenario is empty")
    return value


def validate_record(value, manifest, sequence):
    required = {"format", "producer", "scenario", "sequence", "capturedAt", "mqtt", "payload",
                "normalizationProfile"}
    require_exact_keys(value, required, set(), f"record {sequence}")
    require(value["format"] == FORMAT, f"record {sequence}: unsupported format")
    require(value["producer"] == manifest["producer"], f"record {sequence}: producer mismatch")
    require(value["scenario"] == manifest["scenario"], f"record {sequence}: scenario mismatch")
    require(value["sequence"] == sequence, f"record {sequence}: non-contiguous sequence")
    require(isinstance(value["capturedAt"], str) and value["capturedAt"],
            f"record {sequence}: capturedAt is empty")
    require(value["normalizationProfile"] == "coaty-v1",
            f"record {sequence}: unexpected normalization profile")

    mqtt = value["mqtt"]
    require_exact_keys(mqtt, {"topic", "qos", "retain", "duplicate"}, set(), f"record {sequence}.mqtt")
    require(isinstance(mqtt["topic"], str) and mqtt["topic"], f"record {sequence}: empty topic")
    require(mqtt["qos"] in (0, 1), f"record {sequence}: unsupported QoS")
    require(type(mqtt["retain"]) is bool and type(mqtt["duplicate"]) is bool,
            f"record {sequence}: MQTT flags must be booleans")

    payload = value["payload"]
    require_exact_keys(payload, {"encoding", "bytes"}, set(), f"record {sequence}.payload")
    require(payload["encoding"] == "base64", f"record {sequence}: payload encoding must be base64")
    try:
        decoded = base64.b64decode(payload["bytes"], validate=True)
    except (ValueError, TypeError) as error:
        raise ValidationError(f"record {sequence}: invalid base64 payload") from error
    require(base64.b64encode(decoded).decode("ascii") == payload["bytes"],
            f"record {sequence}: payload base64 is not canonical")
    try:
        json.loads(decoded.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"record {sequence}: payload is not UTF-8 JSON") from error


def validate(capture_path, manifest_path):
    manifest = load_manifest(manifest_path)
    expected_capture = manifest_path.parent / manifest["capture"]["file"]
    require(capture_path.resolve() == expected_capture.resolve(), "capture path does not match manifest filename")
    require(capture_path.is_file(), "capture file does not exist")
    require(sha256(capture_path) == manifest["capture"]["sha256"], "capture SHA-256 mismatch")

    count = 0
    with capture_path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            require(line.endswith("\n"), f"record {line_number}: JSONL line lacks newline terminator")
            require(line.strip(), f"record {line_number}: blank line")
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValidationError(f"record {line_number}: invalid JSON: {error}") from error
            count += 1
            validate_record(record, manifest, count)
    require(count == manifest["capture"]["recordCount"], "capture record count mismatch")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=pathlib.Path)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        count = validate(args.capture, args.manifest)
    except ValidationError as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 1
    print(f"VALID: {count} provenance-bound legacy CoatySwift records")
    return 0


if __name__ == "__main__":
    sys.exit(main())
