#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
: "${AXOLOTY_WIFI_SSID:?AXOLOTY_WIFI_SSID is required}"
: "${AXOLOTY_WIFI_PASSWORD:?AXOLOTY_WIFI_PASSWORD is required}"
: "${AXOLOTY_MQTT_HOST:?AXOLOTY_MQTT_HOST is required}"

device=${EMBEDDED_DEVICE:-/dev/ttyACM1}
project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_dir=${EMBEDDED_BROKER_RESTART_BUILD_DIR:-/workspace/.build/embedded-broker-restart}
output_dir=${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}
managed_broker=${EMBEDDED_BROKER_RESTART_MANAGED:-1}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
reference_dir=$(CDPATH= cd -- "$support_dir/../WireCompatibility/ReferenceAgents/coatyjs" && pwd)
port=${EMBEDDED_BROKER_RESTART_PORT:-1883}
esptool="${IDF_PATH:-/opt/esp/idf}/components/esptool_py/esptool/esptool.py"
config="$build_dir/esp-idf/main/axoloty_network_config.h"
broker_config="$build_dir/mosquitto.conf"
ready_file="$output_dir/embedded-broker-restart-ready"
resume_file="$output_dir/embedded-broker-restart-resume"

cleanup() { rm -f "$config" "$broker_config"; }
trap cleanup EXIT INT TERM
test -e "$device"
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
mkdir -p "$build_dir" "$output_dir"
rm -f "$ready_file" "$resume_file"
cd "$project_dir"
sdkconfig="$build_dir/sdkconfig"
if [ ! -f "$build_dir/CMakeCache.txt" ]; then idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" set-target esp32c6; fi
AXOLOTY_DEVICE_ROLE=B AXOLOTY_AGENT_SCENARIO=broker-restart AXOLOTY_MQTT_PORT="$port" \
  node "$support_dir/generate-embedded-network-config.mjs" "$config"
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build
agent_dir="$build_dir/reference-agent"
mkdir -p "$agent_dir"
cp "$reference_dir/package.json" "$reference_dir/package-lock.json" \
  "$reference_dir/embedded-interoperability-runner.js" "$agent_dir/"
(cd "$agent_dir" && npm ci --omit=optional)
printf 'listener %s\nallow_anonymous true\npersistence false\n' "$port" >"$broker_config"
(cd "$build_dir" && python3 "$esptool" --chip esp32c6 --port "$device" --before default_reset --after no_reset write_flash @flash_args)

SERIAL_TOOLS="$support_dir/../lib/serial-tools.mjs" AGENT_VALIDATOR="$support_dir/embedded-agent-validator.mjs" \
  ESPTOOL="$esptool" RUNNER="$agent_dir/embedded-interoperability-runner.js" BROKER_CONFIG="$broker_config" \
  EMBEDDED_BROKER_RESTART_MANAGED="$managed_broker" node --input-type=module - \
  "$device" "$output_dir" "$AXOLOTY_MQTT_HOST" "$port" "$ready_file" "$resume_file" <<'JS'
import fs from "node:fs";
import { spawn, execFileSync } from "node:child_process";
const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator, expectedBrokerRestartTests } = await import(process.env.AGENT_VALIDATOR);
const [device, output, host, port, readyFile, resumeFile] = process.argv.slice(2);
const managedBroker = process.env.EMBEDDED_BROKER_RESTART_MANAGED !== "0";
const runPeer = scenario => spawn("node", [process.env.RUNNER], {
  env: { ...process.env, BROKER_URL: `mqtt://${host}:${port}`, SCENARIO: scenario },
  stdio: ["ignore", "pipe", "pipe"]
});
const startBroker = () => spawn("mosquitto", ["-c", process.env.BROKER_CONFIG], { stdio: ["ignore", "ignore", "pipe"] });
let broker = managedBroker ? startBroker() : null;
let brokerErrors = [];
broker?.stderr.on("data", chunk => brokerErrors.push(chunk.toString()));
await new Promise(resolve => setTimeout(resolve, 1000));
const collect = child => {
  const lines = []; const errors = [];
  child.stdout.on("data", chunk => { const text = chunk.toString(); process.stdout.write(`[peer] ${text}`); lines.push(...text.trimEnd().split("\n").filter(Boolean)); });
  child.stderr.on("data", chunk => { process.stderr.write(`[peer] ${chunk}`); errors.push(chunk.toString()); });
  const exit = new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", (code, signal) => resolve({ code, signal })); });
  return { child, lines, errors, exit };
};
const stopChild = async child => {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  child.kill("SIGTERM");
  await Promise.race([
    new Promise(resolve => child.once("exit", resolve)),
    new Promise(resolve => setTimeout(resolve, 2000))
  ]);
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
};
const waitForLine = async (collection, state, timeout) => {
  const deadline = Date.now() + timeout;
  while (!collection.lines.some(line => line.includes(`"state":"${state}"`))) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${state}`);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
};
const validator = createEmbeddedAgentValidator(expectedBrokerRestartTests);
const controller = new AbortController();
let observer;
let responder;
try {
  const capture = captureSerial(device, Number(process.env.EMBEDDED_BROKER_RESTART_DEADLINE || "240"), line => {
    console.log(`[B] ${line}`); return validator.observe(line);
  }, controller.signal);
  observer = collect(runPeer("embedded-reconnect-observer"));
  await waitForLine(observer, "ready", 15000);
  execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", device, "run"]);
  await waitForLine(observer, "observed-device-ready", 90000);
  const stoppedAt = new Date().toISOString();
  fs.writeFileSync(readyFile, "ready\n");
  if (managedBroker) {
    broker.kill("SIGKILL");
    await new Promise(resolve => broker.once("exit", resolve));
  } else {
    const deadline = Date.now() + 60000;
    while (!fs.existsSync(resumeFile)) {
      if (Date.now() >= deadline) throw new Error("external broker restart was not resumed");
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  await observer.exit;
  await new Promise(resolve => setTimeout(resolve, 1000));
  if (managedBroker) {
    broker = startBroker();
    broker.stderr.on("data", chunk => brokerErrors.push(chunk.toString()));
  }
  await new Promise(resolve => setTimeout(resolve, 1000));
  responder = collect(runPeer("embedded-responder"));
  await waitForLine(responder, "ready", 15000);
  responder.exit.then(result => { if (result.code !== 0) controller.abort(); });
  const [serialLines, responderExit] = await Promise.all([capture, responder.exit]);
  const serial = validator.result();
  fs.writeFileSync(`${output}/embedded-broker-restart-serial.log`, serialLines.join("\n") + "\n");
  fs.writeFileSync(`${output}/embedded-broker-restart-result.json`, JSON.stringify({ stoppedAt, responderExit, observer: observer.lines, responder: responder.lines, errors: [...observer.errors, ...responder.errors, ...brokerErrors], serial }, null, 2) + "\n");
  if (responderExit.code !== 0 || !serial.passed) throw new Error("embedded broker restart/resubscribe failed");
  console.log("EMBEDDED BROKER RESTART OK");
} finally {
  controller.abort();
  await Promise.all([stopChild(observer?.child), stopChild(responder?.child), stopChild(broker)]);
}
JS
