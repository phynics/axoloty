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
deadline=30
skip_build=${EMBEDDED_SKIP_BUILD:-0}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -e "$device" ]; then
    echo "SMOKE FAIL: $device does not exist (check CONTAINER_DEVICES)" >&2
    exit 1
fi

. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1

mkdir -p "$out_dir"
cd "$project_dir"

if [ "$skip_build" = "0" ]; then
    echo "== set-target =="
    idf.py -B "$build_dir" set-target esp32c6
    echo "== build =="
    idf.py -B "$build_dir" build
fi

echo "== flash =="
if [ "$skip_build" = "1" ]; then
    if [ ! -f "$build_dir/flash_args" ]; then
        echo "SMOKE FAIL: flash-only build metadata missing: $build_dir/flash_args" >&2
        exit 1
    fi
    (
        cd "$build_dir"
        python3 "$IDF_PATH/components/esptool_py/esptool/esptool.py" \
            --chip esp32c6 --port "$device" \
            --before default_reset --after hard_reset \
            write_flash @flash_args
    )
else
    idf.py -B "$build_dir" -p "$device" flash
fi

echo "== monitor (deadline ${deadline}s, structured protocol) =="
SERIAL_TOOLS="$support_dir/serial-tools.mjs" SMOKE_VALIDATOR="$support_dir/embedded-swift-smoke-validator.mjs" node --input-type=module - "$device" "$deadline" "$smoke_log" "$result_file" <<'JS'
import fs from "node:fs";
const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedSwiftSmokeValidator } = await import(process.env.SMOKE_VALIDATOR);
const [device, deadline, log, result] = process.argv.slice(2);
const validator = createEmbeddedSwiftSmokeValidator();
let lines = [];
try {
  lines = await captureSerial(device, Number(deadline), line => {
    console.log(line);
    return validator.observe(line);
  });
  const validation = validator.result();
  fs.writeFileSync(log, lines.join("\n") + "\n");
  fs.writeFileSync(result, JSON.stringify({
    device,
    deadlineSeconds: Number(deadline),
    linesCaptured: lines.length,
    validation,
  }, null, 2) + "\n");
  if (!validation.passed) {
    console.error(`SMOKE FAIL: ${validation.reason}`);
    process.exit(1);
  }
  console.log("SMOKE OK");
} catch (error) {
  console.error(`SMOKE FAIL: cannot capture ${device}: ${error.message}`);
  process.exit(1);
}
JS
