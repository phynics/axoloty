#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Fresh-broker integration for the host MQTTBinding. This runner is deliberately
# separate from offline MQTTBinding fixtures and from the canonical test plan.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }
runtime_bounded() { timeout "${WIRE_CONTAINER_WAIT_SECONDS:-120}s" "$RUNTIME" "$@"; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
LIVE="$ROOT/Tests/Support/WireCompatibility/Live"
TOOL=/tool/dist/index.js
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire/mqtt-binding}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-mqtt-binding-$RUN_ID"
BROKER="axoloty-mqtt-binding-broker-$RUN_ID"
PROBE="axoloty-mqtt-binding-probe-$RUN_ID"
SUBJECT="axoloty-mqtt-binding-subject-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/axoloty-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT/.swiftpm-cache}"
BUILD_DIR="${BUILD_DIR:-/tmp/coaty-swift-build/.git/swift-6.3-linux/debug}"
MODULE_CACHE=/tmp/axoloty-wire-module-cache
NAMESPACE="mqtt-binding-live-$RUN_ID"
CAPTURE="$OUT/mqtt-binding.jsonl"
CAPTURE_READY="$OUT/mqtt-binding.capture-ready"
READY="$OUT/mqtt-binding.ready"
RESTARTED="$OUT/mqtt-binding.broker-restarted"
RESUBSCRIBE_READY="$OUT/mqtt-binding.resubscribe-ready"
APPLICATION_LOG="$OUT/mqtt-binding.application.jsonl"
RAW_LOG="$OUT/mqtt-binding.subject.log"
PEER_LOG="$OUT/mqtt-binding.peer.log"
BROKER_LOG="$OUT/mqtt-binding.broker.log"
PROBE_LOG="$OUT/mqtt-binding.probe.log"
DEADLINE_SECONDS="${WIRE_MQTT_BINDING_DEADLINE_SECONDS:-120}"
RUNTIME_LABELS=(
    --label "io.axoloty.managed-by=${WIRE_RUNTIME_MANAGED_BY:-axoloty-wire-mqtt-binding}"
    --label "io.axoloty.run-id=${WIRE_RUNTIME_RUN_ID:-$RUN_ID}"
    --label "io.axoloty.scenario=${WIRE_RUNTIME_SCENARIO:-mqtt-binding-network}"
)

mkdir -p "$OUT" "$SPM_CACHE_DIR" "$BUILD_DIR"
rm -f "$CAPTURE" "$CAPTURE_READY" "$READY" "$RESTARTED" "$RESUBSCRIBE_READY" \
    "$APPLICATION_LOG" "$RAW_LOG" "$PEER_LOG" "$BROKER_LOG" "$PROBE_LOG"

now() { date +%s; }
wait_for() {
    local description="$1" condition="$2" limit=$(( $(now) + DEADLINE_SECONDS ))
    while ! eval "$condition"; do
        if [ "$(now)" -ge "$limit" ]; then
            echo "Timed out waiting for $description after ${DEADLINE_SECONDS}s" >&2
            echo "Artifacts are retained in $OUT" >&2
            return 1
        fi
        sleep 0.2
    done
}
broker_ready() {
    runtime exec "$BROKER" node -e \
        'const s=require("node:net").createConnection({host:"127.0.0.1",port:1883},()=>s.end()); s.on("error",()=>process.exit(1))' \
        >/dev/null 2>&1
}
start_broker() {
    runtime run -d --name "$BROKER" --network "$NETWORK" "${RUNTIME_LABELS[@]}" \
        -v "$LIVE/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
        "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf >/dev/null
}
collect_diagnostics() {
    runtime logs "$SUBJECT" >"$RAW_LOG" 2>&1 || true
    runtime logs "$BROKER" >"$BROKER_LOG" 2>&1 || true
    runtime logs "$PROBE" >"$PROBE_LOG" 2>&1 || true
    grep -E '^\{"state"' "$RAW_LOG" >"$APPLICATION_LOG" || true
}
cleanup() {
    collect_diagnostics
    runtime rm -f "$SUBJECT" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

runtime network create "$NETWORK" "${RUNTIME_LABELS[@]}" >/dev/null
start_broker
wait_for "Mosquitto broker readiness" broker_ready

runtime run -d --name "$PROBE" --network "$NETWORK" "${RUNTIME_LABELS[@]}" \
    -v "$ROOT/Tests/Support/WireCompatibility/tool:/tool:ro,Z" -v "$OUT:/artifacts" \
    --entrypoint node --user 0 "$JS_IMAGE" "$TOOL" capture '#' "/artifacts/${CAPTURE##*/}" \
    --host "$BROKER" --producer axoloty-mqtt-binding --producer-version current \
    --scenario mqtt-binding-network --ready-file "/artifacts/${CAPTURE_READY##*/}" >"$PROBE_LOG" 2>&1
wait_for "independent MQTT capture subscription" "test -f '$CAPTURE_READY'"

runtime run -d -t --name "$SUBJECT" --network "$NETWORK" "${RUNTIME_LABELS[@]}" \
    -v "$ROOT:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -v "$BUILD_DIR:/swift-build" \
    -v "$OUT:/artifacts" -w /workspace \
    -e WIRE_MQTT_BINDING_NETWORK_LIVE=1 \
    -e WIRE_BROKER_HOST="$BROKER" -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE="$NAMESPACE" \
    -e WIRE_MQTT_BINDING_READY="/artifacts/${READY##*/}" \
    -e WIRE_MQTT_BINDING_RESTARTED="/artifacts/${RESTARTED##*/}" \
    -e WIRE_MQTT_BINDING_RESUBSCRIBE_READY="/artifacts/${RESUBSCRIBE_READY##*/}" \
    -e SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
    "$DEV_IMAGE" swift test -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE" \
    --skip-build --scratch-path /swift-build --cache-path /swiftpm-cache \
    --disable-automatic-resolution --filter MQTTBindingNetworkTests >"$RAW_LOG" 2>&1
wait_for "host MQTTBinding baseline" "test -f '$READY'"

# Restart the broker, then let the subject establish a new binding session and
# re-install its subscriptions. The peer publication below proves fresh
# broker-backed receive after the restart.
runtime logs "$BROKER" >"$OUT/mqtt-binding.broker-before-restart.log" 2>&1 || true
runtime rm -f "$BROKER" >/dev/null
start_broker
wait_for "Mosquitto broker restart readiness" broker_ready
touch "$RESTARTED"
wait_for "host MQTTBinding resubscription" "test -f '$RESUBSCRIBE_READY'"

runtime_bounded run --rm --network "$NETWORK" "${RUNTIME_LABELS[@]}" --entrypoint node \
    -v "$LIVE/coatyjs-advertise-runner.js:/agent/coatyjs-advertise-runner.js:ro" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE="$NAMESPACE" \
    -e SCENARIO_SETTLE_MS=500 "$JS_IMAGE" /agent/coatyjs-advertise-runner.js \
    >"$PEER_LOG" 2>&1

if ! runtime_bounded wait "$SUBJECT" >/dev/null; then
    runtime logs "$SUBJECT" >&2 || true
    exit 1
fi
collect_diagnostics

test -s "$APPLICATION_LOG" || { echo "Swift application log is missing or empty: $APPLICATION_LOG" >&2; exit 1; }
test -s "$CAPTURE" || { echo "Fresh broker capture is missing or empty: $CAPTURE" >&2; exit 1; }
for state in started profile-received receive-filtered external-route-received external-route-deactivated reconnected post-restart-received stopped; do
    grep -q "\"state\":\"$state\"" "$APPLICATION_LOG" || {
        echo "Swift test did not report state $state; see $APPLICATION_LOG" >&2
        exit 1
    }
done
grep -q '/ADV:' "$CAPTURE" || { echo "fresh broker capture has no profile publication: $CAPTURE" >&2; exit 1; }
echo "Application log retained at $APPLICATION_LOG"
echo "Fresh broker capture retained at $CAPTURE"
echo "Subject, broker, probe, and peer diagnostics retained in $OUT"
