#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
: "${AXOLOTY_WIFI_SSID:?AXOLOTY_WIFI_SSID is required}"
: "${AXOLOTY_WIFI_PASSWORD:?AXOLOTY_WIFI_PASSWORD is required}"
: "${AXOLOTY_MQTT_HOST:?AXOLOTY_MQTT_HOST is required}"

role=${EMBEDDED_COATY_ROLE:-A}
device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_root=${EMBEDDED_COATY_BUILD_ROOT:-/workspace/.build/embedded-coatyjs}
output_dir=${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
reference_dir=$(CDPATH= cd -- "$support_dir/../WireCompatibility/ReferenceAgents/coatyjs" && pwd)
esptool="${IDF_PATH:-/opt/esp/idf}/components/esptool_py/esptool/esptool.py"

test -e "$device"
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
mkdir -p "$build_root" "$output_dir"
cd "$project_dir"
build_dir="$build_root/$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')"
sdkconfig="$build_dir/sdkconfig"
config="$build_dir/esp-idf/main/axoloty_network_config.h"
trap 'rm -f "$config"' EXIT
if [ ! -f "$build_dir/CMakeCache.txt" ]; then idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" set-target esp32c6; fi
AXOLOTY_DEVICE_ROLE="$role" node "$support_dir/generate-embedded-network-config.mjs" "$config"
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build
agent_dir="$build_root/reference-agent"
mkdir -p "$agent_dir"
cp "$reference_dir/package.json" "$reference_dir/package-lock.json" \
  "$reference_dir/embedded-interoperability-runner.js" "$agent_dir/"
(cd "$agent_dir" && npm ci --omit=optional)
(cd "$build_dir" && python3 "$esptool" --chip esp32c6 --port "$device" --before default_reset --after no_reset write_flash @flash_args)

SERIAL_TOOLS="$support_dir/../lib/serial-tools.mjs" AGENT_VALIDATOR="$support_dir/embedded-agent-validator.mjs" \
  ESPTOOL="$esptool" RUNNER="$agent_dir/embedded-interoperability-runner.js" node --input-type=module - \
  "$device" "$role" "$output_dir" "$AXOLOTY_MQTT_HOST" "${AXOLOTY_MQTT_PORT:-1883}" <<'JS'
import fs from "node:fs";
import { spawn, execFileSync } from "node:child_process";
const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator } = await import(process.env.AGENT_VALIDATOR);
const [device, role, output, host, port] = process.argv.slice(2);
const scenario = role === "A" ? "embedded-requester" : "embedded-responder";
const validator = createEmbeddedAgentValidator();
const controller = new AbortController();
const capture = captureSerial(device, Number(process.env.EMBEDDED_COATY_DEADLINE || "180"), line => { console.log(`[${role}] ${line}`); return validator.observe(line); }, controller.signal);
const runner = spawn("node", [process.env.RUNNER], {
  env: { ...process.env, BROKER_URL: `mqtt://${host}:${port}`, SCENARIO: scenario },
  stdio: ["ignore", "pipe", "pipe"]
});
const lines = []; let readyResolve; const ready = new Promise(resolve => { readyResolve = resolve; });
runner.stdout.on("data", chunk => { const text = chunk.toString(); process.stdout.write(`[coatyjs] ${text}`); lines.push(...text.trimEnd().split("\n")); if (text.includes('"state":"ready"')) readyResolve(); });
const errors = []; runner.stderr.on("data", chunk => { process.stderr.write(`[coatyjs] ${chunk}`); errors.push(chunk.toString()); });
const exit = new Promise((resolve, reject) => { runner.once("error", reject); runner.once("exit", (code, signal) => { if (code !== 0) controller.abort(); resolve({ code, signal }); }); });
await Promise.race([ready, new Promise((_, reject) => setTimeout(() => reject(new Error("CoatyJS runner did not become ready")), 15000))]);
execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", device, "run"]);
const [serialLines, runnerExit] = await Promise.all([capture, exit]);
fs.writeFileSync(`${output}/embedded-${role.toLowerCase()}-serial.log`, serialLines.join("\n") + "\n");
fs.writeFileSync(`${output}/coatyjs-${role.toLowerCase()}-log.txt`, lines.filter(Boolean).join("\n") + "\n");
fs.writeFileSync(`${output}/coatyjs-${role.toLowerCase()}-result.json`, JSON.stringify({ role, scenario, runnerExit, errors, serial: validator.result() }, null, 2) + "\n");
if (runnerExit.code !== 0 || !validator.result().passed) throw new Error(`embedded↔CoatyJS ${role} failed`);
console.log("EMBEDDED COATYJS INTEROPERABILITY OK");
JS
