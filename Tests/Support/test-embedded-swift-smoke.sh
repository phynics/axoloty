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
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_ESPTOOL_ARGS"
PY
chmod +x "$idf_dir/components/esptool_py/esptool/esptool.py"

run_smoke() {
    case "$1" in success) printf 'booting\nAXOLOTY_SMOKE_OK\n' > "$device";; near-match) printf 'AXOLOTY_SMOKE_OK_FAILED\nGuru Meditation Error\n' > "$device";; padded-marker) printf ' AXOLOTY_SMOKE_OK \r\nGuru Meditation Error\n' > "$device";; *) printf 'Guru Meditation Error\n' > "$device";; esac
    IDF_PATH="$idf_dir" \
    EMBEDDED_DEVICE="$device" EMBEDDED_PROJECT_DIR="$project_dir" \
    EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_OUTPUT_DIR="$out_dir" \
    EMBEDDED_SKIP_BUILD=1 FAKE_ESPTOOL_ARGS="$TEMP_DIR/esptool-args.txt" \
    FAKE_SERIAL_MODE="$1" \
        "$ROOT_DIR/Tests/Support/embedded-swift-smoke.sh"
}

run_smoke success
node --input-type=module - "$out_dir/swift-smoke-result.json" <<'JS'
import fs from "node:fs"; import assert from "node:assert/strict"; const r=JSON.parse(fs.readFileSync(process.argv[2])); assert.equal(r.found,true); assert.equal(r.fatalLine,null); assert.equal(r.linesCaptured,2);
JS
grep -qx -- '--chip' "$TEMP_DIR/esptool-args.txt"
grep -qx -- '@flash_args' "$TEMP_DIR/esptool-args.txt"

if run_smoke fatal; then
    echo "expected fatal serial output to fail" >&2
    exit 1
fi
node --input-type=module - "$out_dir/swift-smoke-result.json" <<'JS'
import fs from "node:fs"; import assert from "node:assert/strict"; const r=JSON.parse(fs.readFileSync(process.argv[2])); assert.equal(r.found,false); assert.equal(r.fatalLine,"Guru Meditation Error");
JS

if run_smoke near-match; then
    echo "expected a near-match marker to fail" >&2
    exit 1
fi
node --input-type=module - "$out_dir/swift-smoke-result.json" <<'JS'
import fs from "node:fs"; import assert from "node:assert/strict"; const r=JSON.parse(fs.readFileSync(process.argv[2])); assert.equal(r.found,false); assert.equal(r.fatalLine,"Guru Meditation Error");
JS

if run_smoke padded-marker; then
    echo "expected a whitespace-padded marker to fail" >&2
    exit 1
fi
node --input-type=module - "$out_dir/swift-smoke-result.json" <<'JS'
import fs from "node:fs"; import assert from "node:assert/strict"; const r=JSON.parse(fs.readFileSync(process.argv[2])); assert.equal(r.found,false); assert.equal(r.fatalLine,"Guru Meditation Error");
JS

rm "$build_dir/flash_args"
if run_smoke success; then
    echo "expected missing flash_args to fail" >&2
    exit 1
fi
