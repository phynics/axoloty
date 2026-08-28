#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=expected-failure.sh
source "$ROOT_DIR/Tests/Support/expected-failure.sh"
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

mkdir -p "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/idf.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

if os.environ.get("FAKE_IDF_FAILURE") == "1":
    raise SystemExit(1)
PY
chmod +x "$TEMP_DIR/bin/idf.py"

cat > "$idf_dir/export.sh" <<'SH'
:
SH
cat > "$idf_dir/components/esptool_py/esptool/esptool.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["FAKE_ESPTOOL_ARGS"], "w", encoding="utf-8") as output:
    if os.environ.get("FAKE_ESPTOOL_FAILURE") == "1":
        raise SystemExit(1)
    output.write("\n".join(sys.argv[1:]) + "\n")
PY
chmod +x "$idf_dir/components/esptool_py/esptool/esptool.py"

success_records() {
    VALIDATOR="$ROOT_DIR/Tests/Support/embedded-swift-smoke-validator.mjs" node --input-type=module <<'JS'
const { makeRecord } = await import(process.env.VALIDATOR);
const names = [
  "topicParse:ADV", "topicParse:DAD", "topicParse:DSC", "topicParse:RSV", "topicParse:CHN", "topicParse:ASC", "topicParse:IOV", "topicParse:raw", "topicParse:filter",
  "dtoDecode:advertise", "dtoDecode:uuid", "dtoDecode:int", "dtoDecode:bool", "dtoDecode:missingField", "malformed:truncated", "malformed:empty", "malformed:invalidUUID",
  "uuid16:parseValid", "uuid16:parseInvalid", "uuid16:zero", "config:payloadMax2048", "config:topicMax128", "config:maxSubscribers8", "config:maxFamilyEntries16",
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

rewrite_records() {
    mode="$1" VALIDATOR="$ROOT_DIR/Tests/Support/embedded-swift-smoke-validator.mjs" node --input-type=module - "$2" <<'JS'
import fs from "node:fs";
const { checksum, makeRecord } = await import(process.env.VALIDATOR);

const mode = process.env.mode;
const records = [];
for (const line of fs.readFileSync(process.argv[2], "utf8").split(/\r?\n/)) {
  if (!line) continue;
  const record = JSON.parse(line);
  if (mode === "no-summary" && record.caseId === "summary") continue;
  if (mode === "bad-counts" && ["summary", "completion"].includes(record.caseId)) record.counts.passed = 23;
  if (mode === "failed" && record.caseId === "topicParse:ADV") {
    record.status = "failed";
    record.diagnostic = "failed check: topicParse:ADV";
  }
  records.push(record);
  if (mode === "reboot" && record.caseId === "topicParse:ADV") {
    records.push(makeRecord(0, "boot", "boot", "started", 0));
  }
}

let previous = 0;
records.forEach((record, sequence) => {
  record.sequence = sequence;
  record.checksum = checksum(record, previous);
  if (record.caseId === "completion") record.finalChecksum = record.checksum;
  console.log(JSON.stringify(record));
  previous = record.checksum;
});
JS
}

run_smoke() {
    rm -f "$out_dir/swift-smoke-result.json" "$out_dir/swift-smoke-log.txt"
    case "$1" in
        success) success_records > "$device" ;;
        missing) success_records | grep -v 'config:maxFamilyEntries16' > "$device" ;;
        duplicate) success_records | sed '/"caseId":"topicParse:ADV"/a {"schemaVersion":2,"runId":"embedded-swift-smoke-v2","sequence":1,"caseId":"topicParse:ADV","operation":"smokeCheck","stage":"execute","status":"passed","checksum":0}' > "$device" ;;
        failed|no-summary|reboot|bad-counts) success_records > "$TEMP_DIR/records"; rewrite_records "$1" "$TEMP_DIR/records" > "$device" ;;
        nonmonotonic) success_records | sed '0,/"sequence":2/s//"sequence":1/' > "$device" ;;
        checksum) success_records | sed '0,/"checksum":[0-9]*/s//"checksum":0/' > "$device" ;;
        unknown) success_records | sed '0,/"caseId":"topicParse:ADV"/s//"caseId":"unknown"/' > "$device" ;;
        no-completion) success_records | sed '/"caseId":"completion"/d' > "$device" ;;
        malformed) printf '{not-json}\n' > "$device" ;;
        *) printf 'Guru Meditation Error\n' > "$device" ;;
    esac
    test_device="$device" test_skip_build=1 test_idf_failure=0 test_esptool_failure=0 test_validator_factory=createEmbeddedSwiftSmokeValidator
    case "$1" in
        setup-failure) test_device="$TEMP_DIR/missing-device" ;;
        build-failure) test_skip_build=0 test_idf_failure=1 ;;
        flash-failure) test_esptool_failure=1 ;;
        capture-failure) test_validator_factory=missingValidator ;;
    esac
    IDF_PATH="$idf_dir" \
    PATH="$TEMP_DIR/bin:$PATH" \
    EMBEDDED_DEVICE="$test_device" EMBEDDED_PROJECT_DIR="$project_dir" \
    EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_OUTPUT_DIR="$out_dir" \
    EMBEDDED_DEADLINE=1 \
    EMBEDDED_SKIP_BUILD="$test_skip_build" EMBEDDED_VALIDATOR_FACTORY="$test_validator_factory" \
    FAKE_IDF_FAILURE="$test_idf_failure" FAKE_ESPTOOL_FAILURE="$test_esptool_failure" \
    FAKE_ESPTOOL_ARGS="$TEMP_DIR/esptool-args.txt" FAKE_SERIAL_MODE="$1" \
        "$ROOT_DIR/Tests/Support/embedded-swift-smoke.sh"
}

assert_failure_result() {
    mode="$1"
    expected_stage="$2"
    expected_diagnostic="$3"
    run_expected_failure "embedded-swift-smoke/$mode" any run_smoke "$mode"
    node --input-type=module - "$out_dir/swift-smoke-result.json" "$expected_stage" "$expected_diagnostic" <<'JS'
import fs from "node:fs";
import assert from "node:assert/strict";
const [resultPath, expectedStage, expectedDiagnostic] = process.argv.slice(2);
const result = JSON.parse(fs.readFileSync(resultPath));
assert.equal(result.validation.passed, false);
assert.equal(result.validation.stage, expectedStage);
assert.match(result.validation.diagnostic, new RegExp(expectedDiagnostic));
assert.match(result.validation.reason, new RegExp(expectedDiagnostic));
assert.ok(result.validation.diagnostic.length <= 256);
JS
}

run_smoke success
node --input-type=module - "$out_dir/swift-smoke-result.json" <<'JS'
import fs from "node:fs"; import assert from "node:assert/strict"; const r=JSON.parse(fs.readFileSync(process.argv[2])); assert.equal(r.schemaVersion,2); assert.equal(r.runId,"embedded-swift-smoke-v2"); assert.equal(r.validation.passed,true); assert.equal(r.linesCaptured,27);
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

VALIDATOR="$ROOT_DIR/Tests/Support/embedded-swift-smoke-validator.mjs" node --input-type=module <<'JS'
import assert from "node:assert/strict";
const { checksum, makeRecord, evidenceStages, failureResult } = await import(process.env.VALIDATOR);
assert.deepEqual(evidenceStages, ["setup", "build", "flash", "capture", "boot", "execute", "summary", "completion"]);
const record = makeRecord(0, "boot", "boot", "started", 0);
assert.notEqual(checksum({ ...record, stage: "capture" }, 0), record.checksum);
assert.equal(failureResult("execute", "x".repeat(1000)).diagnostic.length, 256);
JS

for mode in fatal missing duplicate nonmonotonic unknown; do
    run_expected_failure "embedded-swift-smoke/$mode" any run_smoke "$mode"
done

assert_failure_result failed execute "failed check: topicParse:ADV"
assert_failure_result malformed capture "malformed JSON record"
assert_failure_result checksum capture "checksum mismatch"
assert_failure_result reboot boot "unexpected reboot"
assert_failure_result bad-counts summary "invalid summary counts"
assert_failure_result no-summary summary "missing summary record"
assert_failure_result no-completion completion "missing completion record"

for mode in setup-failure build-failure flash-failure capture-failure; do
    run_expected_failure "embedded-swift-smoke/$mode" any run_smoke "$mode"
    node --input-type=module - "$out_dir/swift-smoke-result.json" "$mode" <<'JS'
import fs from "node:fs";
import assert from "node:assert/strict";
const [resultPath, mode] = process.argv.slice(2);
const expectedStage = mode.replace("-failure", "");
const result = JSON.parse(fs.readFileSync(resultPath));
assert.equal(result.schemaVersion, 2);
assert.equal(result.runId, "embedded-swift-smoke-v2");
assert.equal(result.validation.passed, false);
assert.equal(result.validation.stage, expectedStage);
assert.equal(typeof result.validation.diagnostic, "string");
assert.ok(result.validation.diagnostic.length > 0);
assert.ok(result.validation.diagnostic.length <= 256);
JS
done

rm "$build_dir/flash_args"
run_expected_failure "embedded-swift-smoke/missing-flash-args" any run_smoke success

# The wrapper must label fixture output, while an unwrapped failure remains a
# normal actionable diagnostic for the surrounding self-test.
expected_output="$TEMP_DIR/expected-output.log"
run_expected_failure "embedded-swift-smoke/label-check" any run_smoke malformed >"$expected_output" 2>&1
grep -q '^\[expected:embedded-swift-smoke/label-check\] SMOKE FAIL:' "$expected_output"
unexpected_output="$TEMP_DIR/unexpected-output.log"
if run_smoke malformed >"$unexpected_output" 2>&1; then
    echo "malformed smoke fixture unexpectedly passed" >&2
    exit 1
fi
grep -q '^SMOKE FAIL:' "$unexpected_output"
if grep -q '^\[expected:' "$unexpected_output"; then
    echo "unexpected fixture diagnostic was mislabeled" >&2
    exit 1
fi
