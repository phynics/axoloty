#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

project_dir="$TEMP_DIR/project"
build_dir="$TEMP_DIR/build"
out_dir="$TEMP_DIR/results"
idf_dir="$TEMP_DIR/idf"
device="$TEMP_DIR/device"
mkdir -p "$project_dir" "$build_dir" "$out_dir" \
    "$idf_dir/components/esptool_py/esptool"
: > "$device"
: > "$build_dir/flash_args"

cat > "$idf_dir/export.sh" <<'SH'
:
SH
cat > "$idf_dir/components/esptool_py/esptool/esptool.py" <<'PY'
from pathlib import Path
import os
import sys

Path(os.environ["FAKE_ESPTOOL_ARGS"]).write_text("\n".join(sys.argv[1:]) + "\n")
PY
cat > "$TEMP_DIR/serial.py" <<'PY'
import os


class SerialException(Exception):
    pass


class Serial:
    def __init__(self, device, baud, timeout):
        del device, baud, timeout
        mode = os.environ["FAKE_SERIAL_MODE"]
        if mode == "success":
            self.lines = [b"booting\n", b"AXOLOTY_SMOKE_OK\n"]
        elif mode == "near-match":
            self.lines = [
                b"AXOLOTY_SMOKE_OK_FAILED\n",
                b"Guru Meditation Error\n",
            ]
        elif mode == "padded-marker":
            self.lines = [
                b" AXOLOTY_SMOKE_OK \r\n",
                b"Guru Meditation Error\n",
            ]
        else:
            self.lines = [b"Guru Meditation Error\n"]

    def reset_input_buffer(self):
        pass

    def readline(self):
        return self.lines.pop(0) if self.lines else b""

    def close(self):
        pass
PY

run_smoke() {
    PYTHONPATH="$TEMP_DIR" IDF_PATH="$idf_dir" \
    EMBEDDED_DEVICE="$device" EMBEDDED_PROJECT_DIR="$project_dir" \
    EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_OUTPUT_DIR="$out_dir" \
    EMBEDDED_SKIP_BUILD=1 FAKE_ESPTOOL_ARGS="$TEMP_DIR/esptool-args.txt" \
    FAKE_SERIAL_MODE="$1" \
        "$ROOT_DIR/Tests/Support/embedded-swift-smoke.sh"
}

run_smoke success
python3 - "$out_dir/swift-smoke-result.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as result_file:
    result = json.load(result_file)
assert result["found"] is True
assert result["fatalLine"] is None
assert result["linesCaptured"] == 2
PY
grep -qx -- '--chip' "$TEMP_DIR/esptool-args.txt"
grep -qx -- '@flash_args' "$TEMP_DIR/esptool-args.txt"

if run_smoke fatal; then
    echo "expected fatal serial output to fail" >&2
    exit 1
fi
python3 - "$out_dir/swift-smoke-result.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as result_file:
    result = json.load(result_file)
assert result["found"] is False
assert result["fatalLine"] == "Guru Meditation Error"
PY

if run_smoke near-match; then
    echo "expected a near-match marker to fail" >&2
    exit 1
fi
python3 - "$out_dir/swift-smoke-result.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as result_file:
    result = json.load(result_file)
assert result["found"] is False
assert result["fatalLine"] == "Guru Meditation Error"
PY

if run_smoke padded-marker; then
    echo "expected a whitespace-padded marker to fail" >&2
    exit 1
fi
python3 - "$out_dir/swift-smoke-result.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as result_file:
    result = json.load(result_file)
assert result["found"] is False
assert result["fatalLine"] == "Guru Meditation Error"
PY

rm "$build_dir/flash_args"
if run_smoke success; then
    echo "expected missing flash_args to fail" >&2
    exit 1
fi
