#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
REVERSE_DIR="$ROOT_DIR/Tests/WireCompatibility/Reverse"
LIVE_DIR="$ROOT_DIR/Tests/WireCompatibility/Live"
REFERENCE_DIR="$ROOT_DIR/Tests/WireCompatibility/ReferenceAgents"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-wire-reverse-$RUN_ID"
BROKER="axoloty-wire-reverse-broker-$RUN_ID"
CONSUMER="axoloty-wire-reverse-consumer-$RUN_ID"
PROBE="axoloty-wire-reverse-probe-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
CONSUMER_LOG=$(mktemp)
OUTPUT_DIR="${WIRE_OUTPUT_DIR:-$ROOT_DIR/.testing/wire}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"

cleanup() {
    runtime rm -f "$CONSUMER" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -f "$CONSUMER_LOG"
}
trap cleanup EXIT INT TERM
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/axoloty-advertise.jsonl"

runtime build -t "$DEV_IMAGE" -f "$ROOT_DIR/.devcontainer/Dockerfile" "$ROOT_DIR/.devcontainer"
runtime build -t "$JS_IMAGE" "$REFERENCE_DIR/coatyjs"
runtime network create "$NETWORK" >/dev/null
runtime run -d --name "$BROKER" --network "$NETWORK" \
    -v "$LIVE_DIR/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
    "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf >/dev/null

for _ in $(seq 1 30); do
    runtime exec "$BROKER" python3 -c 'import socket; socket.create_connection(("127.0.0.1", 1883), 1).close()' >/dev/null 2>&1 && break
    sleep 0.2
done

runtime run -d --name "$PROBE" --network "$NETWORK" \
    -v "$ROOT_DIR:/workspace:ro" -v "$OUTPUT_DIR:/artifacts" \
    --entrypoint node --user 0 "$JS_IMAGE" /workspace/Tests/WireCompatibility/tool/dist/index.js capture '#' /artifacts/axoloty-advertise.jsonl \
    --host "$BROKER" --producer coatyswift-modern --producer-version current \
    --scenario axoloty-advertise >/dev/null
sleep 0.5

runtime run -d --name "$CONSUMER" --network "$NETWORK" --entrypoint node \
    -v "$REVERSE_DIR/coatyjs-advertise-consumer.js:/agent/reverse-consumer.js:ro,Z" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE=wire-compat-v1 \
    -e SCENARIO_TIMEOUT_MS=60000 \
    "$JS_IMAGE" /agent/reverse-consumer.js >/dev/null

for _ in $(seq 1 30); do
    runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
    grep -q '"state":"ready"' "$CONSUMER_LOG" && break
    sleep 0.2
done
grep -q '"state":"ready"' "$CONSUMER_LOG" || { cat "$CONSUMER_LOG" >&2; exit 1; }

runtime run --rm --network "$NETWORK" -v "$ROOT_DIR:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -w /workspace \
    -e WIRE_REVERSE_LIVE=1 -e WIRE_BROKER_HOST="$BROKER" \
    -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE=wire-compat-v1 \
    "$DEV_IMAGE" swift test --cache-path /swiftpm-cache --disable-automatic-resolution --filter AxolotyAdvertiseProducerTests

sleep 0.5
runtime stop -t 1 "$PROBE" >/dev/null || true

runtime wait "$CONSUMER" >/dev/null
runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
cat "$CONSUMER_LOG"
grep -q '"state":"ack"' "$CONSUMER_LOG"
echo "PASS: Axoloty Advertise decoded by CoatyJS 2.4.0"
