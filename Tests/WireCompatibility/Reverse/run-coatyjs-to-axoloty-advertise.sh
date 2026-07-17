#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# The JS -> modern direction of the Advertise capability: pinned CoatyJS 2.4.0
# is the producer and Axoloty (modern Swift, as the subject under test) is the
# consumer whose decoded Swift object must match the deterministic fixture
# published on the wire. This is the mirror of run-axoloty-advertise.sh, which
# covers modern Swift producing for a CoatyJS consumer.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
REVERSE_DIR="$ROOT_DIR/Tests/WireCompatibility/Reverse"
LIVE_DIR="$ROOT_DIR/Tests/WireCompatibility/Live"
REFERENCE_DIR="$ROOT_DIR/Tests/WireCompatibility/ReferenceAgents"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-wire-js-to-modern-$RUN_ID"
BROKER="axoloty-wire-js-to-modern-broker-$RUN_ID"
CONSUMER="axoloty-wire-js-to-modern-consumer-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
CONSUMER_LOG=$(mktemp)

cleanup() {
    runtime rm -f "$CONSUMER" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -f "$CONSUMER_LOG"
}
trap cleanup EXIT INT TERM

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

# Axoloty is the subject: start it detached so this script can wait for it to
# report a subscription-acquired "ready" line before the CoatyJS producer
# publishes, then run the CoatyJS producer synchronously to completion.
runtime run -d --name "$CONSUMER" --network "$NETWORK" \
    -v "$ROOT_DIR:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -w /workspace \
    -e WIRE_JS_TO_MODERN_LIVE=1 -e WIRE_BROKER_HOST="$BROKER" \
    -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE=wire-compat-v1 \
    "$DEV_IMAGE" swift test --cache-path /swiftpm-cache --disable-automatic-resolution --filter AxolotyAdvertiseConsumerTests >/dev/null

for _ in $(seq 1 60); do
    runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
    grep -q '"state":"ready"' "$CONSUMER_LOG" && break
    sleep 0.5
done
grep -q '"state":"ready"' "$CONSUMER_LOG" || { cat "$CONSUMER_LOG" >&2; echo "Axoloty consumer never reported readiness" >&2; exit 1; }

runtime run --rm --network "$NETWORK" --entrypoint node \
    -v "$LIVE_DIR/coatyjs-advertise-runner.js:/agent/coatyjs-advertise-runner.js:ro" \
    -e BROKER_URL="mqtt://$BROKER:1883" \
    -e COATY_NAMESPACE=wire-compat-v1 \
    -e SCENARIO_SETTLE_MS=1500 \
    "$JS_IMAGE" /agent/coatyjs-advertise-runner.js

runtime wait "$CONSUMER" >/dev/null
runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
cat "$CONSUMER_LOG"
grep -q '"state":"ack"' "$CONSUMER_LOG"
echo "PASS: CoatyJS Advertise decoded by Axoloty (modern Swift)"
