#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
podman() { command "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LIVE_DIR="$ROOT_DIR/Tests/WireCompatibility/Live"
REFERENCE_DIR="$ROOT_DIR/Tests/WireCompatibility/ReferenceAgents"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="coatyswift-wire-core-$RUN_ID"
BROKER="coatyswift-wire-core-broker-$RUN_ID"
PROBE="coatyswift-wire-core-probe-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
OUTPUT_DIR="${WIRE_OUTPUT_DIR:-$ROOT_DIR/.testing/wire}"

cleanup() {
    podman rm -f "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    podman network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTPUT_DIR"
podman build -t "$DEV_IMAGE" -f "$ROOT_DIR/.devcontainer/Dockerfile" "$ROOT_DIR/.devcontainer"
podman build -t "$JS_IMAGE" "$REFERENCE_DIR/coatyjs"
podman network create "$NETWORK" >/dev/null
podman run -d --name "$BROKER" --network "$NETWORK" \
    -v "$LIVE_DIR/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
    "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf >/dev/null

for _ in $(seq 1 30); do
    if podman exec "$BROKER" python3 -c \
        'import socket; socket.create_connection(("127.0.0.1", 1883), 1).close()' \
        >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
if ! podman exec "$BROKER" python3 -c \
    'import socket; socket.create_connection(("127.0.0.1", 1883), 1).close()' \
    >/dev/null 2>&1; then
    podman logs "$BROKER" >&2
    echo "Mosquitto did not become ready" >&2
    exit 1
fi

SCENARIOS="${WIRE_SCENARIOS:-deadvertise channel discover-resolve query-retrieve update-complete call-return}"
for scenario in $SCENARIOS; do
    capture="coatyjs-$scenario.jsonl"
    rm -f "$OUTPUT_DIR/$capture"
    podman run -d --name "$PROBE" --network "$NETWORK" \
        -v "$ROOT_DIR:/workspace:ro" -v "$OUTPUT_DIR:/artifacts" \
        "$DEV_IMAGE" python3 /workspace/Tests/WireCompatibility/Capture/mqtt_capture.py \
        --host "$BROKER" --topic '#' \
        --producer coatyjs --producer-version 2.4.0 --scenario "$scenario" \
        --output "/artifacts/$capture" >/dev/null
    sleep 0.5
    podman run --rm --network "$NETWORK" --entrypoint node \
        -v "$LIVE_DIR/coatyjs-core-runner.js:/agent/coatyjs-core-runner.js:ro" \
        -e BROKER_URL="mqtt://$BROKER:1883" \
        -e COATY_NAMESPACE=wire-compat-v1 \
        -e SCENARIO="$scenario" \
        -e SCENARIO_SETTLE_MS=500 \
        "$JS_IMAGE" /agent/coatyjs-core-runner.js
    sleep 0.25
    podman stop -t 1 "$PROBE" >/dev/null
    podman rm "$PROBE" >/dev/null
    podman run --rm \
        -v "$ROOT_DIR:/workspace:ro" -v "$OUTPUT_DIR:/artifacts:ro" \
        "$DEV_IMAGE" python3 /workspace/Tests/WireCompatibility/Live/verify-coatyjs-core.py \
        "$scenario" "/artifacts/$capture"
    echo "Capture retained at $OUTPUT_DIR/$capture"
done
