#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Containerized live runner for the `duplicate-reply` and `late-reply`
# lifecycle scenarios. Axoloty (modern Swift) is the Call/Return initiator
# against pinned CoatyJS 2.4.0 as a (deliberately misbehaving, for these
# scenarios) Call responder. See
# Tests/WireCompatibility/Lifecycle/AxolotyLifecycleSubjectTests.swift for the
# Axoloty side and
# Tests/WireCompatibility/Reverse/coatyjs-core-consumer.js for the CoatyJS
# responder side.
#
# Every broker, probe, responder, and subject runs on one isolated runtime
# network. It does not depend on host Mosquitto/Swift.
set -euo pipefail

SCENARIO="${1:?Usage: run-lifecycle-call-return.sh <duplicate-reply|late-reply>}"
case "$SCENARIO" in
    duplicate-reply|late-reply) ;;
    *) echo "Unsupported scenario for this runner: $SCENARIO" >&2; exit 64 ;;
esac

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
HERE="$ROOT/Tests/WireCompatibility/Lifecycle/Live"
REVERSE="$ROOT/Tests/WireCompatibility/Reverse"
REF="$ROOT/Tests/WireCompatibility/ReferenceAgents/coatyjs"
TOOL=/tool/dist/index.js
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-call-return-$SCENARIO-$RUN_ID"
BROKER="axoloty-callreturn-broker-$RUN_ID"
PROBE="axoloty-callreturn-probe-$RUN_ID"
RESPONDER="axoloty-callreturn-responder-$RUN_ID"
SUBJECT="axoloty-callreturn-subject-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT/.swiftpm-cache}"
BUILD_DIR="${BUILD_DIR:-/tmp/coaty-swift-build/.git/swift-6.3-linux/debug}"
NAMESPACE="wire-lifecycle-$SCENARIO-$RUN_ID"
CAPTURE="$OUT/axoloty-$SCENARIO.jsonl"
CAPTURE_READY="$OUT/axoloty-$SCENARIO.capture-ready"
CONSUMER_LOG="$OUT/coatyjs-$SCENARIO.consumer.log"
APPLICATION_LOG="$OUT/axoloty-$SCENARIO.application.jsonl"
RAW_LOG="$OUT/axoloty-$SCENARIO.subject.log"
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-600}"

cleanup() {
    runtime logs "$SUBJECT" >"$OUT/subject-container-$SCENARIO.log" 2>&1 || true
    runtime logs "$RESPONDER" >"$OUT/responder-container-$SCENARIO.log" 2>&1 || true
    runtime logs "$PROBE" >"$OUT/probe-container-$SCENARIO.log" 2>&1 || true
    runtime logs "$BROKER" >"$OUT/broker-container-$SCENARIO.log" 2>&1 || true
    runtime rm -f "$SUBJECT" "$RESPONDER" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
mkdir -p "$OUT"
rm -f "$CAPTURE" "$CAPTURE_READY" "$CONSUMER_LOG" "$APPLICATION_LOG" "$RAW_LOG"

runtime build -t "$DEV_IMAGE" -f "$ROOT/.devcontainer/Dockerfile" "$ROOT/.devcontainer"
runtime build -t "$JS_IMAGE" "$REF"
runtime network create "$NETWORK" >/dev/null

start_broker() {
    runtime run -d --name "$BROKER" --network "$NETWORK" \
        -v "$HERE/../../Live/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
        "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf >/dev/null
}
wait_for() {
    local description="$1" condition="$2" limit=$(( $(date +%s) + DEADLINE_SECONDS ))
    while ! eval "$condition"; do
        if [ "$(date +%s)" -ge "$limit" ]; then echo "Timed out waiting for $description" >&2; return 1; fi
        sleep 0.2
    done
}
broker_ready() { runtime exec "$BROKER" python3 -c 'import socket; socket.create_connection(("127.0.0.1",1883),1).close()' >/dev/null 2>&1; }
start_broker
wait_for "Mosquitto broker readiness" broker_ready

# Start capture probe.
rm -f "$CAPTURE_READY"
runtime run -d --name "$PROBE" --network "$NETWORK" -v "$ROOT/Tests/WireCompatibility/tool:/tool:ro,Z" -v "$OUT:/artifacts" \
    --entrypoint node --user 0 "$JS_IMAGE" "$TOOL" capture '#' "/artifacts/${CAPTURE##*/}" \
    --host "$BROKER" --producer coatyswift-modern --producer-version current --scenario "$SCENARIO" \
    --ready-file "/artifacts/${CAPTURE_READY##*/}" >/dev/null
wait_for "capture subscription" "test -f '$CAPTURE_READY'"

# Start CoatyJS Call responder.
runtime run -d --name "$RESPONDER" --network "$NETWORK" \
    --entrypoint node \
    -v "$REVERSE/coatyjs-core-consumer.js:/agent/coatyjs-core-consumer.js:ro" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE="$NAMESPACE" \
    -e SCENARIO="$SCENARIO" -e SCENARIO_TIMEOUT_MS=30000 \
    -e LIFECYCLE_LATE_REPLY_DELAY_MS="${LIFECYCLE_LATE_REPLY_DELAY_MS:-4000}" \
    "$JS_IMAGE" /agent/coatyjs-core-consumer.js >/dev/null
responder_ready() { runtime logs "$RESPONDER" 2>&1 >"$CONSUMER_LOG"; grep -q '"state":"ready"' "$CONSUMER_LOG"; }
wait_for "CoatyJS Call responder readiness" responder_ready

# Run the Swift test subject.
TEST_NAME="AxolotyLifecycleSubjectTests/$(
    case "$SCENARIO" in
        duplicate-reply) echo duplicateReply ;;
        late-reply) echo lateReply ;;
    esac
)"
ENV_FLAG="$(
    case "$SCENARIO" in
        duplicate-reply) echo WIRE_LIFECYCLE_DUPLICATE_REPLY_LIVE ;;
        late-reply) echo WIRE_LIFECYCLE_LATE_REPLY_LIVE ;;
    esac
)"
runtime run -d -t --name "$SUBJECT" --network "$NETWORK" \
    -v "$ROOT:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -v "$BUILD_DIR:/swift-build" -w /workspace \
    -e "$ENV_FLAG=1" -e WIRE_BROKER_HOST="$BROKER" -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE="$NAMESPACE" \
    "$DEV_IMAGE" swift test --skip-build --scratch-path /swift-build --cache-path /swiftpm-cache --disable-automatic-resolution \
    --filter "$TEST_NAME" >/dev/null

# Wait for the Swift test to complete.
runtime wait "$SUBJECT" >/dev/null
runtime logs "$SUBJECT" 2>&1 >"$RAW_LOG"
grep -E '^\{"state":' "$RAW_LOG" >"$APPLICATION_LOG" || true

# Verify responder ack.
runtime logs "$RESPONDER" 2>&1 >"$CONSUMER_LOG"
grep -q '"state":"ack"' "$CONSUMER_LOG" || { echo "CoatyJS responder did not ack; see $CONSUMER_LOG" >&2; exit 1; }

# Verify capture.
runtime rm -f "$PROBE" >/dev/null 2>&1 || true
sleep 0.3
test -s "$CAPTURE" || { echo "Capture is missing or empty: $CAPTURE" >&2; exit 1; }

echo "Application log retained at $APPLICATION_LOG"
echo "Capture retained at $CAPTURE"
