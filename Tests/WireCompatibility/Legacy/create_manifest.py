#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Create the provenance manifest for a macOS-generated legacy capture."""

import argparse
import datetime
import hashlib
import json
import pathlib
import platform
import subprocess


def command_output(command):
    return subprocess.check_output(command, text=True).strip().replace("\n", " ")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-repository", default="https://github.com/coatyio/coaty-swift.git")
    parser.add_argument("--scenario", required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("manifests for reference captures may only be generated on macOS")
    content = args.capture.read_bytes()
    record_count = sum(1 for line in content.splitlines() if line)
    value = {
        "format": "coaty-legacy-capture-manifest/v1",
        "capture": {
            "file": args.capture.name,
            "sha256": hashlib.sha256(content).hexdigest(),
            "recordCount": record_count,
        },
        "producer": {"implementation": "coatyswift-legacy", "version": args.version},
        "source": {"repository": args.source_repository, "commit": args.source_commit},
        "runner": {
            "os": "macOS",
            "architecture": platform.machine(),
            "swiftVersion": command_output(["swift", "--version"]),
            "xcodeVersion": command_output(["xcodebuild", "-version"]),
            "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        },
        "scenario": args.scenario,
    }
    args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
