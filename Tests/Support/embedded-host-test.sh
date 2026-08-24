#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
: "${AXOLOTY_WIFI_SSID:?AXOLOTY_WIFI_SSID is required}"
: "${AXOLOTY_WIFI_PASSWORD:?AXOLOTY_WIFI_PASSWORD is required}"
: "${AXOLOTY_MQTT_HOST:?AXOLOTY_MQTT_HOST is required}"

role=${EMBEDDED_HOST_ROLE:-A}
device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_root=${EMBEDDED_HOST_BUILD_ROOT:-/workspace/.build/embedded-host}
swift_build=${EMBEDDED_HOST_SWIFT_BUILD:-/workspace/.build/embedded-host-swift}
output_dir=${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$support_dir/../.." && pwd)
esptool="${IDF_PATH:-/opt/esp/idf}/components/esptool_py/esptool/esptool.py"

case "$role" in A) direction=host-requester ;; B) direction=host-responder ;; *) echo "EMBEDDED_HOST_ROLE must be A or B" >&2; exit 2 ;; esac
test -e "$device"
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
mkdir -p "$build_root" "$swift_build" "$output_dir"
cd "$project_dir"
build_dir="$build_root/$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')"
sdkconfig="$build_dir/sdkconfig"
config="$build_dir/esp-idf/main/axoloty_network_config.h"
ready="$output_dir/host-$role.ready"
trap 'rm -f "$config" "$ready"' EXIT
rm -f "$ready"
if [ ! -f "$build_dir/CMakeCache.txt" ]; then idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" set-target esp32c6; fi
AXOLOTY_DEVICE_ROLE="$role" node "$support_dir/generate-embedded-network-config.mjs" "$config"
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build
(cd "$build_dir" && python3 "$esptool" --chip esp32c6 --port "$device" --before default_reset --after no_reset write_flash @flash_args)

SERIAL_TOOLS="$support_dir/serial-tools.mjs" AGENT_VALIDATOR="$support_dir/embedded-agent-validator.mjs" \
  ESPTOOL="$esptool" ROOT="$root" SWIFT_BUILD="$swift_build" node --input-type=module - \
  "$device" "$role" "$direction" "$output_dir" "$AXOLOTY_MQTT_HOST" "${AXOLOTY_MQTT_PORT:-1883}" "$ready" <<'JS'
import fs from "node:fs";
import { spawn, execFileSync } from "node:child_process";
const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator } = await import(process.env.AGENT_VALIDATOR);
const [device, role, direction, output, host, port, readyFile] = process.argv.slice(2);
const validator = createEmbeddedAgentValidator();
const child = spawn("swift", ["test", "--target", "AxolotyLiveWireTests", "--scratch-path", process.env.SWIFT_BUILD, "--filter", "EmbeddedHostInteroperabilityTests"], {
  cwd: process.env.ROOT,
  env: { ...process.env, WIRE_EMBEDDED_HOST_LIVE: "1", WIRE_EMBEDDED_HOST_DIRECTION: direction,
    WIRE_BROKER_HOST: host, WIRE_BROKER_PORT: port, WIRE_READY_FILE: readyFile },
  stdio: ["ignore", "pipe", "pipe"]
});
const hostOutput = [];
for (const stream of [child.stdout, child.stderr]) stream.on("data", chunk => { process.stdout.write(`[host] ${chunk}`); hostOutput.push(chunk.toString()); });
const exit = new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", (code, signal) => resolve({ code, signal })); });
const controller = new AbortController();
let earlyHostExit;
exit.then(result => { earlyHostExit = result; if (result.code !== 0) controller.abort(); });
try {
  const deadline = Date.now() + Number(process.env.EMBEDDED_HOST_BUILD_DEADLINE || "600000");
  while (!fs.existsSync(readyFile)) {
    if (earlyHostExit) throw new Error(`host Axoloty exited before readiness (${earlyHostExit.code})`);
    if (Date.now() >= deadline) throw new Error("host Axoloty did not become ready");
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const capture = captureSerial(device, Number(process.env.EMBEDDED_HOST_DEADLINE || "240"), line => {
    console.log(`[${role}] ${line}`); return validator.observe(line);
  }, controller.signal).then(lines => {
    if (!validator.result().passed && child.exitCode === null) child.kill("SIGTERM");
    return lines;
  });
  execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", device, "run"]);
  const [serialLines, hostExit] = await Promise.all([capture, exit]);
  const serial = validator.result();
  fs.writeFileSync(`${output}/embedded-host-${role.toLowerCase()}-serial.log`, serialLines.join("\n") + "\n");
  fs.writeFileSync(`${output}/embedded-host-${role.toLowerCase()}-result.json`, JSON.stringify({ role, direction, hostExit, serial }, null, 2) + "\n");
  fs.writeFileSync(`${output}/embedded-host-${role.toLowerCase()}-host.log`, hostOutput.join(""));
  if (hostExit.code !== 0 || !serial.passed) throw new Error(`embedded↔host Axoloty ${role} failed`);
  console.log("EMBEDDED HOST INTEROPERABILITY OK");
} finally {
  controller.abort();
  if (child.exitCode === null) child.kill("SIGTERM");
}
JS
