#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build, flash, and monitor the ESP32-C6 Embedded Swift image (issue #321).
#
# Runs inside the $(IMAGE)-embedded container. Sources ESP-IDF, sets the
# target, builds, flashes, then captures serial output for up to 30 seconds.
# The firmware emits a strict structured JSON Lines protocol; success requires
# all expected passed records and the final completion record.
#
# Writes a monitor log and structured result to EMBEDDED_OUTPUT_DIR. The Make
# target mirrors both files into the durable .testing/embedded directory.

set -eu

device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}"
smoke_log="$out_dir/swift-smoke-log.txt"
result_file="$out_dir/swift-smoke-result.json"
project_dir="${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}"
build_dir="${EMBEDDED_BUILD_DIR:-$project_dir/build}"
deadline=${EMBEDDED_DEADLINE:-120}
skip_build=${EMBEDDED_SKIP_BUILD:-0}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
schema_version=2
run_id=embedded-swift-smoke-v2
max_diagnostic_length=256

write_failure() {
    if [ -f "$result_file" ]; then return; fi
    FAILURE_STAGE="$1" FAILURE_REASON="$2" RESULT_FILE="$result_file" \
        FAILURE_DEVICE="$device" FAILURE_DEADLINE="$deadline" \
        FAILURE_SCHEMA_VERSION="$schema_version" FAILURE_RUN_ID="$run_id" \
        FAILURE_MAX_DIAGNOSTIC_LENGTH="$max_diagnostic_length" node --input-type=module <<'JS'
import fs from "node:fs";
const diagnostic = String(process.env.FAILURE_REASON).slice(
  0, Number(process.env.FAILURE_MAX_DIAGNOSTIC_LENGTH),
);
fs.writeFileSync(process.env.RESULT_FILE, JSON.stringify({
  schemaVersion: Number(process.env.FAILURE_SCHEMA_VERSION),
  runId: process.env.FAILURE_RUN_ID,
  device: process.env.FAILURE_DEVICE,
  deadlineSeconds: Number(process.env.FAILURE_DEADLINE),
  linesCaptured: 0,
  validation: {
    passed: false,
    stage: process.env.FAILURE_STAGE,
    diagnostic,
    reason: diagnostic,
  },
}, null, 2) + "\n");
JS
}

failure_stage=setup
trap 'status=$?; trap - EXIT; if [ "$status" -ne 0 ]; then write_failure "$failure_stage" "embedded command failed during $failure_stage"; fi; exit "$status"' EXIT

mkdir -p "$out_dir"
rm -f "$smoke_log" "$result_file"

if [ ! -e "$device" ]; then
    write_failure setup "$device does not exist (check CONTAINER_DEVICES)"
    echo "SMOKE FAIL: $device does not exist (check CONTAINER_DEVICES)" >&2
    exit 1
fi

if ! . "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1; then
    write_failure setup "unable to load ESP-IDF environment"
    exit 1
fi
if ! cd "$project_dir"; then
    write_failure setup "embedded project directory is unavailable: $project_dir"
    exit 1
fi

if [ "$skip_build" = "0" ]; then
    failure_stage=build
    echo "== set-target =="
    if ! idf.py -B "$build_dir" set-target esp32c6; then
        write_failure build "ESP-IDF set-target failed for esp32c6 (inspect the build output)"
        exit 1
    fi
    echo "== build =="
    if ! idf.py -B "$build_dir" build; then
        write_failure build "ESP-IDF build failed (inspect the build output)"
        exit 1
    fi
fi

failure_stage=flash
echo "== flash =="
if [ "$skip_build" = "1" ]; then
    if [ ! -f "$build_dir/flash_args" ]; then
        write_failure flash "flash metadata missing: $build_dir/flash_args"
        echo "SMOKE FAIL: flash-only build metadata missing: $build_dir/flash_args" >&2
        exit 1
    fi
    if ! (
        cd "$build_dir"
        python3 "$IDF_PATH/components/esptool_py/esptool/esptool.py" \
            --chip esp32c6 --port "$device" \
            --before default_reset --after hard_reset \
            write_flash @flash_args
    ); then
        write_failure flash "esptool flash failed for $device (check the serial device and flash_args)"
        exit 1
    fi
else
    if ! idf.py -B "$build_dir" -p "$device" flash; then
        write_failure flash "ESP-IDF flash failed for $device (check the serial device)"
        exit 1
    fi
fi

failure_stage=capture
echo "== monitor (deadline ${deadline}s, structured protocol) =="
SERIAL_TOOLS="$support_dir/../lib/serial-tools.mjs" SMOKE_VALIDATOR="${EMBEDDED_VALIDATOR:-$support_dir/embedded-swift-smoke-validator.mjs}" SMOKE_VALIDATOR_FACTORY="${EMBEDDED_VALIDATOR_FACTORY:-createEmbeddedSwiftSmokeValidator}" node --input-type=module - "$device" "$deadline" "$smoke_log" "$result_file" <<'JS'
import fs from "node:fs";
const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const validatorModule = await import(process.env.SMOKE_VALIDATOR);
const createValidator = validatorModule[process.env.SMOKE_VALIDATOR_FACTORY];
const schemaVersion = validatorModule.schemaVersion;
const runId = validatorModule.expectedRunId;
const maxDiagnosticLength = validatorModule.maxDiagnosticLength;
const [device, deadline, log, result] = process.argv.slice(2);
const boundedDiagnostic = value => String(value).slice(0, maxDiagnosticLength);
if (typeof createValidator !== "function") {
  throw new Error(`missing validator factory: ${process.env.SMOKE_VALIDATOR_FACTORY}`);
}
const validator = createValidator();
let lines = [];
const writeResult = validation => fs.writeFileSync(result, JSON.stringify({
  schemaVersion,
  runId,
  device,
  deadlineSeconds: Number(deadline),
  linesCaptured: lines.length,
  validation,
}, null, 2) + "\n");
try {
  lines = await captureSerial(device, Number(deadline), line => {
    console.log(line);
    return validator.observe(line);
  });
  const validation = validator.result();
  fs.writeFileSync(log, lines.join("\n") + "\n");
  writeResult(validation);
  if (!validation.passed) {
    console.error(`SMOKE FAIL: ${validation.reason}`);
    process.exit(1);
  }
  console.log("SMOKE OK");
} catch (error) {
  const diagnostic = boundedDiagnostic(`cannot capture ${device}: ${error?.message ?? String(error)}`);
  fs.writeFileSync(log, lines.join("\n") + (lines.length ? "\n" : ""));
  writeResult({ passed: false, stage: "capture", diagnostic, reason: diagnostic });
  console.error(`SMOKE FAIL: cannot capture ${device}: ${error.message}`);
  process.exit(1);
}
JS
