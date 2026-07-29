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
    VALIDATOR="$ROOT_DIR/Tests/Support/embedded-swift-smoke-validator.mjs" node --input-type=module <<'JS'
const { makeRecord } = await import(process.env.VALIDATOR);
const names = [
  "topicParse:ADV", "topicParse:DAD", "topicParse:DSC", "topicParse:RSV", "topicParse:CHN", "topicParse:ASC", "topicParse:IOV", "topicParse:raw", "topicParse:filter",
  "dtoDecode:advertise", "dtoDecode:uuid", "dtoDecode:int", "dtoDecode:bool", "dtoDecode:missingField", "malformed:truncated", "malformed:empty", "malformed:invalidUUID",
  "uuid16:parseValid", "uuid16:parseInvalid", "uuid16:zero", "config:payloadMax512", "config:topicMax128", "config:maxSubscribers8", "config:maxFamilyEntries16",
];
let previous = 0;
for (let sequence = 0; sequence < names.length + 3; sequence++) {
  let record;
  if (sequence === 0) record = makeRecord(0, "boot", "boot", "started", previous);
  else if (sequence <= names.length) record = makeRecord(sequence, names[sequence - 1], "smokeCheck", "passed", previous);
  else if (sequence === names.length + 1) record = makeRecord(sequence, "summary", "summary", "completed", previous, { passed: 24, failed: 0 });
  else {
    record = makeRecord(sequence, "completion", "complete", "completed", previous, { passed: 24, failed: 0 });
    record.finalChecksum = record.checksum;
  }
  console.log(JSON.stringify(record)); previous = record.checksum;
}
JS
}

run_smoke() {
    case "$1" in
        success) success_records > "$device" ;;
        missing) success_records | grep -v 'config:maxFamilyEntries16' > "$device" ;;
        duplicate) success_records | sed '/"caseId":"topicParse:ADV"/a {"schemaVersion":1,"runId":"embedded-swift-smoke-v1","sequence":1,"caseId":"topicParse:ADV","operation":"smokeCheck","status":"passed","checksum":0}' > "$device" ;;
        failed) success_records | sed 's/"caseId":"topicParse:ADV","operation":"smokeCheck","status":"passed"/"caseId":"topicParse:ADV","operation":"smokeCheck","status":"failed"/' > "$device" ;;
        nonmonotonic) success_records | sed '0,/"sequence":2/s//"sequence":1/' > "$device" ;;
        checksum) success_records | sed '0,/"checksum":[0-9]*/s//"checksum":0/' > "$device" ;;
        unknown) success_records | sed '0,/"caseId":"topicParse:ADV"/s//"caseId":"unknown"/' > "$device" ;;
        no-completion) success_records | sed '/"caseId":"completion"/d' > "$device" ;;
        bad-counts) success_records | sed 's/"passed":24/"passed":23/' > "$device" ;;
        malformed) printf '{not-json}\n' > "$device" ;;
        reboot) success_records | sed '/"caseId":"topicParse:ADV"/a {"schemaVersion":1,"runId":"embedded-swift-smoke-v1","sequence":2,"caseId":"boot","operation":"boot","status":"started","checksum":0}' > "$device" ;;
        *) printf 'Guru Meditation Error\n' > "$device" ;;
    esac
    IDF_PATH="$idf_dir" \
    EMBEDDED_DEVICE="$device" EMBEDDED_PROJECT_DIR="$project_dir" \
    EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_OUTPUT_DIR="$out_dir" \
    EMBEDDED_DEADLINE=1 \
    EMBEDDED_SKIP_BUILD=1 FAKE_ESPTOOL_ARGS="$TEMP_DIR/esptool-args.txt" \
    FAKE_SERIAL_MODE="$1" \
        "$ROOT_DIR/Tests/Support/embedded-swift-smoke.sh"
}

run_smoke success
node --input-type=module - "$out_dir/swift-smoke-result.json" <<'JS'
import fs from "node:fs"; import assert from "node:assert/strict"; const r=JSON.parse(fs.readFileSync(process.argv[2])); assert.equal(r.validation.passed,true); assert.equal(r.linesCaptured,27);
JS
grep -qx -- '--chip' "$TEMP_DIR/esptool-args.txt"
grep -qx -- '@flash_args' "$TEMP_DIR/esptool-args.txt"

VALIDATOR="$ROOT_DIR/Tests/Support/embedded-swift-smoke-validator.mjs" node --input-type=module <<'JS'
import assert from "node:assert/strict";
const { createEmbeddedSwiftSmokeValidator } = await import(process.env.VALIDATOR);
const validator = createEmbeddedSwiftSmokeValidator();
assert.equal(validator.observe("E (5271) task_wdt: Task watchdog got triggered."), true);
assert.match(validator.result().reason, /fatal device output/);
JS

for mode in fatal missing duplicate failed malformed reboot nonmonotonic checksum unknown no-completion bad-counts; do
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
