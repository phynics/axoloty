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
import os
import sys

with open(os.environ["FAKE_ESPTOOL_ARGS"], "w", encoding="utf-8") as output:
    output.write("\n".join(sys.argv[1:]) + "\n")
PY
chmod +x "$idf_dir/components/esptool_py/esptool/esptool.py"

success_records() {
    cat <<'EOF'
booting
{"phase":"boot","status":"started"}
{"test":"topicParse:ADV","status":"passed"}
{"test":"topicParse:DAD","status":"passed"}
{"test":"topicParse:DSC","status":"passed"}
{"test":"topicParse:RSV","status":"passed"}
{"test":"topicParse:CHN","status":"passed"}
{"test":"topicParse:ASC","status":"passed"}
{"test":"topicParse:IOV","status":"passed"}
{"test":"topicParse:raw","status":"passed"}
{"test":"topicParse:filter","status":"passed"}
{"test":"dtoDecode:advertise","status":"passed"}
{"test":"dtoDecode:uuid","status":"passed"}
{"test":"dtoDecode:int","status":"passed"}
{"test":"dtoDecode:bool","status":"passed"}
{"test":"dtoDecode:missingField","status":"passed"}
{"test":"malformed:truncated","status":"passed"}
{"test":"malformed:empty","status":"passed"}
{"test":"malformed:invalidUUID","status":"passed"}
{"test":"uuid16:parseValid","status":"passed"}
{"test":"uuid16:parseInvalid","status":"passed"}
{"test":"uuid16:zero","status":"passed"}
{"test":"config:payloadMax512","status":"passed"}
{"test":"config:topicMax128","status":"passed"}
{"test":"config:maxSubscribers8","status":"passed"}
{"test":"config:maxFamilyEntries16","status":"passed"}
{"tests":{"passed":24,"failed":0}}
{"phase":"smoke","status":"completed"}
EOF
}

run_smoke() {
    case "$1" in
        success) success_records > "$device" ;;
        missing) success_records | grep -v 'config:maxFamilyEntries16' > "$device" ;;
        duplicate) success_records | sed '/"test":"topicParse:ADV"/a {"test":"topicParse:ADV","status":"passed"}' > "$device" ;;
        failed) success_records | sed 's/"test":"topicParse:ADV","status":"passed"/"test":"topicParse:ADV","status":"failed"/' > "$device" ;;
        malformed) printf '{not-json}\n' > "$device" ;;
        reboot) success_records | sed '/"test":"topicParse:ADV"/a {"phase":"boot","status":"started"}' > "$device" ;;
        *) printf 'Guru Meditation Error\n' > "$device" ;;
    esac
    IDF_PATH="$idf_dir" \
    EMBEDDED_DEVICE="$device" EMBEDDED_PROJECT_DIR="$project_dir" \
    EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_OUTPUT_DIR="$out_dir" \
    EMBEDDED_SKIP_BUILD=1 FAKE_ESPTOOL_ARGS="$TEMP_DIR/esptool-args.txt" \
    FAKE_SERIAL_MODE="$1" \
        "$ROOT_DIR/Tests/Support/embedded-swift-smoke.sh"
}

run_smoke success
node --input-type=module - "$out_dir/swift-smoke-result.json" <<'JS'
import fs from "node:fs"; import assert from "node:assert/strict"; const r=JSON.parse(fs.readFileSync(process.argv[2])); assert.equal(r.validation.passed,true); assert.equal(r.linesCaptured,28);
JS
grep -qx -- '--chip' "$TEMP_DIR/esptool-args.txt"
grep -qx -- '@flash_args' "$TEMP_DIR/esptool-args.txt"

for mode in fatal missing duplicate failed malformed reboot; do
    if run_smoke "$mode"; then
        echo "expected $mode serial output to fail" >&2
        exit 1
    fi
done

rm "$build_dir/flash_args"
if run_smoke success; then
    echo "expected missing flash_args to fail" >&2
    exit 1
fi
