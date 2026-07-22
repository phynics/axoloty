#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# The JS -> modern direction of IO scenario 1 (Associate generated route):
# pinned CoatyJS 2.4.0 is the IO router + source (producer) and Axoloty
# (modern Swift) is the IO actor (consumer) under test. CoatyJS publishes an
# Associate that omits `isExternalRoute`; Axoloty must decode it without
# trapping (the isExternalRoute fix), associate, and receive the bare IoValue.
# Mirrors Reverse/run-coatyjs-to-axoloty-advertise.sh.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
IO_DIR="$ROOT_DIR/Tests/WireCompatibility/IO"
LIVE_DIR="$ROOT_DIR/Tests/WireCompatibility/Live"
REFERENCE_DIR="$ROOT_DIR/Tests/WireCompatibility/ReferenceAgents"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-wire-io-j2m-$RUN_ID"
BROKER="axoloty-wire-io-j2m-broker-$RUN_ID"
SOURCE="axoloty-wire-io-j2m-source-$RUN_ID"
CONSUMER="axoloty-wire-io-j2m-consumer-$RUN_ID"
PROBE="axoloty-wire-io-j2m-probe-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
CONSUMER_LOG=$(mktemp)
OUTPUT_DIR="${WIRE_OUTPUT_DIR:-$ROOT_DIR/.testing/wire/io/associate-js-to-modern}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"

cleanup() {
    runtime rm -f "$SOURCE" "$CONSUMER" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -f "$CONSUMER_LOG"
}
trap cleanup EXIT INT TERM
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/io-associate-js-to-modern.jsonl"

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
    --entrypoint node --user 0 "$JS_IMAGE" /workspace/Tests/WireCompatibility/tool/dist/index.js capture '#' /artifacts/io-associate-js-to-modern.jsonl \
    --host "$BROKER" --producer coatyjs --producer-version 2.4.0 \
    --scenario io-associate-js-to-modern >/dev/null
sleep 0.5

# Axoloty (actor/consumer) is the subject: start it detached so this script can
# wait for its "ready" line before the CoatyJS producer publishes. The timeout
# is generous because the in-container cold build can take several minutes.
# `-t` allocates a TTY: without it `swift test` block-buffers the child test
# binary's stdout when it is a pipe, so the "ready" line never reaches the log
# and the readiness handshake below would time out.
runtime run -d -t --name "$CONSUMER" --network "$NETWORK" \
    -v "$ROOT_DIR:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -w /workspace \
    -e WIRE_IO_JS_TO_MODERN_LIVE=1 -e WIRE_BROKER_HOST="$BROKER" \
    -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE=wire-compat-v1 \
    "$DEV_IMAGE" swift test --cache-path /swiftpm-cache --disable-automatic-resolution --filter AxolotyIoAssociateTests >/dev/null

for _ in $(seq 1 240); do
    runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
    grep -q '"state":"ready"' "$CONSUMER_LOG" && break
    sleep 0.5
done
grep -q '"state":"ready"' "$CONSUMER_LOG" || { cat "$CONSUMER_LOG" >&2; echo "Axoloty consumer never reported readiness" >&2; exit 1; }

# CoatyJS is the producer: publishes Associate (no isExternalRoute) + IoValue.
runtime run --rm --network "$NETWORK" --entrypoint node \
    -v "$IO_DIR/coatyjs-io-runner.js:/agent/coatyjs-io-runner.js:ro,Z" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE=wire-compat-v1 \
    -e ROLE=associate-source -e IO_EXPECTED_VALUES=1 -e SCENARIO_SETTLE_MS=1500 \
    "$JS_IMAGE" /agent/coatyjs-io-runner.js

runtime wait "$CONSUMER" >/dev/null
runtime logs "$CONSUMER" >"$CONSUMER_LOG" 2>&1
cat "$CONSUMER_LOG"
grep -q '"state":"ack"' "$CONSUMER_LOG"
echo "PASS: CoatyJS IO Associate + IoValue decoded by Axoloty (modern Swift)"
