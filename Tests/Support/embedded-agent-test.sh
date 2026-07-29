#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu
: "${AXOLOTY_WIFI_SSID:?AXOLOTY_WIFI_SSID is required}"
: "${AXOLOTY_WIFI_PASSWORD:?AXOLOTY_WIFI_PASSWORD is required}"

device_a=${EMBEDDED_DEVICE_A:-/dev/ttyACM0}
device_b=${EMBEDDED_DEVICE_B:-/dev/ttyACM1}
project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_root=${EMBEDDED_AGENT_BUILD_ROOT:-/workspace/.build/embedded-agent}
output_dir=${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
esptool="${IDF_PATH:-/opt/esp/idf}/components/esptool_py/esptool/esptool.py"

for device in "$device_a" "$device_b"; do
  test -e "$device" || { echo "embedded agent test requires $device" >&2; exit 2; }
done
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
mkdir -p "$build_root" "$output_dir"
cd "$project_dir"

config_a="$build_root/a/esp-idf/main/axoloty_network_config.h"
config_b="$build_root/b/esp-idf/main/axoloty_network_config.h"
trap 'rm -f "$config_a" "$config_b"' EXIT

build_role() {
  role=$1
  build_dir=$2
  sdkconfig="$build_dir/sdkconfig"
  if [ ! -f "$build_dir/CMakeCache.txt" ]; then
    idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" set-target esp32c6
  fi
  AXOLOTY_DEVICE_ROLE="$role" node "$support_dir/generate-embedded-network-config.mjs" \
    "$build_dir/esp-idf/main/axoloty_network_config.h"
  idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build
}

build_role A "$build_root/a"
build_role B "$build_root/b"
if [ "${EMBEDDED_AGENT_BUILD_ONLY:-0}" = "1" ]; then
  echo "embedded agent role builds passed"
  exit 0
fi

flash_without_reset() {
  device=$1
  build_dir=$2
  (
    cd "$build_dir"
    python3 "$esptool" --chip esp32c6 --port "$device" \
      --before default_reset --after no_reset write_flash @flash_args
  )
}

flash_without_reset "$device_b" "$build_root/b"
flash_without_reset "$device_a" "$build_root/a"

SERIAL_TOOLS="$support_dir/serial-tools.mjs" \
AGENT_VALIDATOR="$support_dir/embedded-agent-validator.mjs" \
ESPTOOL="$esptool" node --input-type=module - \
  "$device_a" "$device_b" "$output_dir" <<'JS'
import fs from "node:fs";
import { execFileSync } from "node:child_process";
const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator } = await import(process.env.AGENT_VALIDATOR);
const [deviceA, deviceB, output] = process.argv.slice(2);

const capture = (device, role) => {
  const validator = createEmbeddedAgentValidator();
  return captureSerial(device, 180, line => {
    console.log(`[${role}] ${line}`);
    return validator.observe(line);
  }).then(lines => ({ role, device, lines, validation: validator.result() }));
};

const captureA = capture(deviceA, "A");
const captureB = capture(deviceB, "B");
await new Promise(resolve => setTimeout(resolve, 100));
execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", deviceB, "run"]);
execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", deviceA, "run"]);
const results = await Promise.all([captureA, captureB]);
for (const result of results) {
  fs.writeFileSync(`${output}/agent-${result.role.toLowerCase()}-log.txt`, result.lines.join("\n") + "\n");
  fs.writeFileSync(`${output}/agent-${result.role.toLowerCase()}-result.json`, JSON.stringify(result, null, 2) + "\n");
  if (!result.validation.passed) throw new Error(`device ${result.role}: ${result.validation.reason}`);
}
console.log("EMBEDDED AGENT EXCHANGE OK");
JS
