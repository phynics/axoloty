#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
: "${AXOLOTY_WIFI_SSID:?AXOLOTY_WIFI_SSID is required}"
: "${AXOLOTY_WIFI_PASSWORD:?AXOLOTY_WIFI_PASSWORD is required}"
: "${AXOLOTY_MQTT_HOST:?AXOLOTY_MQTT_HOST is required}"

device_a=${EMBEDDED_DEVICE_A:-/dev/ttyACM0}
device_b=${EMBEDDED_DEVICE_B:-/dev/ttyACM1}
project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_root=${EMBEDDED_LAST_WILL_BUILD_ROOT:-/workspace/.build/embedded-last-will}
output_dir=${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
reference_dir=$(CDPATH= cd -- "$support_dir/../WireCompatibility/ReferenceAgents/coatyjs" && pwd)
esptool="${IDF_PATH:-/opt/esp/idf}/components/esptool_py/esptool/esptool.py"

for device in "$device_a" "$device_b"; do test -e "$device"; done
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
mkdir -p "$build_root" "$output_dir"
cd "$project_dir"
config_a="$build_root/a/esp-idf/main/axoloty_network_config.h"
config_b="$build_root/b/esp-idf/main/axoloty_network_config.h"
trap 'rm -f "$config_a" "$config_b"' EXIT

build_role() {
  role=$1; build_dir=$2; sdkconfig="$build_dir/sdkconfig"
  if [ ! -f "$build_dir/CMakeCache.txt" ]; then idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" set-target esp32c6; fi
  AXOLOTY_DEVICE_ROLE="$role" AXOLOTY_AGENT_SCENARIO=last-will \
    node "$support_dir/generate-embedded-network-config.mjs" "$build_dir/esp-idf/main/axoloty_network_config.h"
  idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build
}
build_role A "$build_root/a"
build_role B "$build_root/b"
agent_dir="$build_root/reference-agent"
mkdir -p "$agent_dir"
cp "$reference_dir/package.json" "$reference_dir/package-lock.json" \
  "$reference_dir/embedded-interoperability-runner.js" "$agent_dir/"
(cd "$agent_dir" && npm ci --omit=optional)
for pair in "$device_b:$build_root/b" "$device_a:$build_root/a"; do
  device=${pair%%:*}; build_dir=${pair#*:}
  (cd "$build_dir" && python3 "$esptool" --chip esp32c6 --port "$device" --before default_reset --after no_reset write_flash @flash_args)
done

SERIAL_TOOLS="$support_dir/../lib/serial-tools.mjs" AGENT_VALIDATOR="$support_dir/embedded-agent-validator.mjs" \
  ESPTOOL="$esptool" RUNNER="$agent_dir/embedded-interoperability-runner.js" node --input-type=module - \
  "$device_a" "$device_b" "$output_dir" "$AXOLOTY_MQTT_HOST" "${AXOLOTY_MQTT_PORT:-1883}" <<'JS'
import fs from "node:fs";
import { spawn, execFileSync } from "node:child_process";
const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator, expectedLastWillTests } = await import(process.env.AGENT_VALIDATOR);
const [deviceA, deviceB, output, host, port] = process.argv.slice(2);
const validator = createEmbeddedAgentValidator(expectedLastWillTests);
const controller = new AbortController();
const capture = captureSerial(deviceB, Number(process.env.EMBEDDED_LAST_WILL_DEADLINE || "180"), line => {
  console.log(`[B] ${line}`); return validator.observe(line);
}, controller.signal);
const runner = spawn("node", [process.env.RUNNER], {
  env: { ...process.env, BROKER_URL: `mqtt://${host}:${port}`, SCENARIO: "embedded-last-will-observer" },
  stdio: ["ignore", "pipe", "pipe"]
});
const runnerLines = []; let readyResolve; let deviceReadyResolve; let advertisedResolve; let peerAdvertisedResolve;
const ready = new Promise(resolve => { readyResolve = resolve; });
const deviceReady = new Promise(resolve => { deviceReadyResolve = resolve; });
const advertised = new Promise(resolve => { advertisedResolve = resolve; });
const peerAdvertised = new Promise(resolve => { peerAdvertisedResolve = resolve; });
runner.stdout.on("data", chunk => {
  const text = chunk.toString(); process.stdout.write(`[observer] ${text}`);
  for (const line of text.trimEnd().split("\n")) {
    if (!line) continue; runnerLines.push(line);
    if (line.includes('"state":"ready"')) readyResolve();
    if (line.includes('"state":"observed-device-ready"')) deviceReadyResolve();
    if (line.includes('"state":"observed-advertise"')) advertisedResolve();
    if (line.includes('"state":"observed-peer-advertise"')) peerAdvertisedResolve();
  }
});
const errors = []; runner.stderr.on("data", chunk => { process.stderr.write(`[observer] ${chunk}`); errors.push(chunk.toString()); });
const runnerExit = new Promise((resolve, reject) => { runner.once("error", reject); runner.once("exit", (code, signal) => { if (code !== 0) controller.abort(); resolve({ code, signal }); }); });
await Promise.race([ready, new Promise((_, reject) => setTimeout(() => reject(new Error("last-will observer not ready")), 15000))]);
execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", deviceB, "run"]);
await Promise.race([deviceReady, new Promise((_, reject) => setTimeout(() => reject(new Error("embedded observer did not become ready")), 90000))]);
execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", deviceA, "run"]);
await Promise.race([advertised, new Promise((_, reject) => setTimeout(() => reject(new Error("embedded Advertise not observed")), 90000))]);
await Promise.race([peerAdvertised, new Promise((_, reject) => setTimeout(() => reject(new Error("device B did not observe embedded Advertise")), 15000))]);
const forcedResetAt = new Date().toISOString();
execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", deviceA, "run"]);
const [serialLines, observerExit] = await Promise.all([capture, runnerExit]);
const serial = validator.result();
const observerPassed = observerExit.code === 0 && runnerLines.some(line => line.includes('"state":"observed-last-will"'));
fs.writeFileSync(`${output}/embedded-last-will-b-serial.log`, serialLines.join("\n") + "\n");
fs.writeFileSync(`${output}/embedded-last-will-observer.jsonl`, runnerLines.join("\n") + "\n");
fs.writeFileSync(`${output}/embedded-last-will-result.json`, JSON.stringify({ forcedResetAt, observerExit, observerPassed, errors, serial }, null, 2) + "\n");
if (!observerPassed || !serial.passed) throw new Error("embedded unexpected-disconnect last will failed");
console.log("EMBEDDED LAST WILL OK");
JS
