#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Live-gated, one-direction interoperability matrix: Axoloty produces each
# core event and pinned CoatyJS 2.4.0 decodes it and acknowledges semantics.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
REVERSE_DIR="$ROOT_DIR/Tests/WireCompatibility/Reverse"
LIVE_DIR="$ROOT_DIR/Tests/WireCompatibility/Live"
REFERENCE_DIR="$ROOT_DIR/Tests/WireCompatibility/ReferenceAgents"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-wire-core-$RUN_ID"
BROKER="axoloty-wire-core-broker-$RUN_ID"
CONSUMER="axoloty-wire-core-consumer-$RUN_ID"
PROBE="axoloty-wire-core-probe-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
OUTPUT_DIR="${WIRE_OUTPUT_DIR:-$ROOT_DIR/.testing/wire}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
CONSUMER_LOG=$(mktemp)

cleanup() {
    runtime rm -f "$CONSUMER" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -f "$CONSUMER_LOG"
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTPUT_DIR"
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
runtime exec "$BROKER" python3 -c 'import socket; socket.create_connection(("127.0.0.1", 1883), 1).close()' >/dev/null

SCENARIOS="${WIRE_SCENARIOS:-deadvertise channel discover-resolve query-retrieve update-complete call-return}"
for scenario in $SCENARIOS; do
    capture="$OUTPUT_DIR/axoloty-$scenario.jsonl"
    rm -f "$capture"
    runtime run -d --name "$PROBE" --network "$NETWORK" \
        -v "$ROOT_DIR:/workspace:ro" -v "$OUTPUT_DIR:/artifacts" \
        "$DEV_IMAGE" python3 /workspace/Tests/WireCompatibility/Capture/mqtt_capture.py \
        --host "$BROKER" --topic '#' --producer axoloty-modern --producer-version current \
        --scenario "axoloty-$scenario" --output "/artifacts/axoloty-$scenario.jsonl" >/dev/null
    sleep 0.5

    runtime run -d --name "$CONSUMER" --network "$NETWORK" --entrypoint node \
        -v "$REVERSE_DIR/coatyjs-core-consumer.js:/agent/coatyjs-core-consumer.js:ro,Z" \
        -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE=wire-compat-v1 \
        -e SCENARIO="$scenario" -e SCENARIO_TIMEOUT_MS=60000 \
        "$JS_IMAGE" /agent/coatyjs-core-consumer.js >/dev/null
    for _ in $(seq 1 30); do
        runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
        grep -q '"state":"ready"' "$CONSUMER_LOG" && break
        sleep 0.2
    done
    grep -q '"state":"ready"' "$CONSUMER_LOG" || { cat "$CONSUMER_LOG" >&2; exit 1; }

    runtime run --rm --network "$NETWORK" -v "$ROOT_DIR:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -w /workspace \
        -e WIRE_REVERSE_LIVE=1 -e WIRE_SCENARIO="$scenario" \
        -e WIRE_BROKER_HOST="$BROKER" -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE=wire-compat-v1 \
        "$DEV_IMAGE" swift test --cache-path /swiftpm-cache --disable-automatic-resolution --filter AxolotyCoreProducerTests

    runtime wait "$CONSUMER" >/dev/null
    runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
    cat "$CONSUMER_LOG"
    grep -q '"state":"ack"' "$CONSUMER_LOG"
    runtime stop -t 1 "$PROBE" >/dev/null || true
    runtime rm "$PROBE" >/dev/null
    echo "Capture retained at $capture"
done

echo "PASS: Axoloty core events decoded by CoatyJS 2.4.0"
