#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Native (no container runtime) live runner for the `duplicate-reply` and
# `late-reply` lifecycle scenarios. Unlike the other scripts in this
# directory, these two scenarios use Axoloty (modern Swift) as the live
# subject -- the Call/Return initiator -- against pinned CoatyJS 2.4.0 as a
# (deliberately misbehaving, for these scenarios) Call responder. See
# Tests/WireCompatibility/Lifecycle/AxolotyLifecycleSubjectTests.swift for the
# Axoloty side and Tests/WireCompatibility/Reverse/coatyjs-core-consumer.js
# for the CoatyJS responder side.
#
# This host has no docker/podman, so this script runs mosquitto, node, and
# `swift test` directly as native macOS processes rather than containers,
# matching the precedent set by coatyjs-last-will-runner.js /
# coatyjs-qos-runner.js before they were containerized.
set -euo pipefail

SCENARIO="${1:?Usage: run-lifecycle-call-return.sh <duplicate-reply|late-reply>}"
case "$SCENARIO" in
    duplicate-reply|late-reply) ;;
    *) echo "Unsupported scenario for this runner: $SCENARIO" >&2; exit 64 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
HERE="$ROOT/Tests/WireCompatibility/Lifecycle/Live"
REVERSE="$ROOT/Tests/WireCompatibility/Reverse"
REF="$ROOT/Tests/WireCompatibility/ReferenceAgents/coatyjs"
MOSQUITTO="${MOSQUITTO_BIN:-/opt/homebrew/opt/mosquitto/sbin/mosquitto}"
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
RUN_ID="${WIRE_RUN_ID:-$$}"
NAMESPACE="wire-lifecycle-$SCENARIO-$RUN_ID"
CAPTURE="$OUT/axoloty-$SCENARIO.jsonl"
CAPTURE_READY="$OUT/axoloty-$SCENARIO.capture-ready"
CONSUMER_LOG="$OUT/coatyjs-$SCENARIO.consumer.log"
APPLICATION_LOG="$OUT/axoloty-$SCENARIO.application.jsonl"
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-30}"

MOSQUITTO_PID=""
CAPTURE_PID=""
CONSUMER_PID=""
cleanup() {
    [ -n "$CONSUMER_PID" ] && kill "$CONSUMER_PID" >/dev/null 2>&1 || true
    [ -n "$CAPTURE_PID" ] && kill "$CAPTURE_PID" >/dev/null 2>&1 || true
    [ -n "$MOSQUITTO_PID" ] && kill "$MOSQUITTO_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$OUT"
rm -f "$CAPTURE" "$CAPTURE_READY" "$CONSUMER_LOG" "$APPLICATION_LOG"

if ! command -v "$MOSQUITTO" >/dev/null 2>&1; then
    echo "mosquitto binary not found at $MOSQUITTO (set MOSQUITTO_BIN)" >&2
    exit 1
fi

"$MOSQUITTO" -c "$HERE/../../Live/mosquitto.conf" >"$OUT/mosquitto-$SCENARIO.log" 2>&1 &
MOSQUITTO_PID=$!

deadline() { date +%s; }
wait_for() {
    local description="$1" condition="$2" limit=$(( $(deadline) + DEADLINE_SECONDS ))
    while ! eval "$condition"; do
        if [ "$(deadline)" -ge "$limit" ]; then
            echo "Timed out waiting for $description after ${DEADLINE_SECONDS}s" >&2
            return 1
        fi
        sleep 0.1
    done
}
wait_for "Mosquitto broker readiness" "python3 -c 'import socket; socket.create_connection((\"127.0.0.1\",1883),1).close()' >/dev/null 2>&1"

node "$ROOT/Tests/WireCompatibility/tool/dist/index.js" capture '#' "$CAPTURE" \
    --host 127.0.0.1 --producer coatyswift-modern --producer-version current \
    --scenario "$SCENARIO" --ready-file "$CAPTURE_READY" \
    >"$OUT/capture-$SCENARIO.log" 2>&1 &
CAPTURE_PID=$!
wait_for "capture subscription" "test -f '$CAPTURE_READY'"

NODE_PATH="$REF/node_modules" BROKER_URL="mqtt://127.0.0.1:1883" COATY_NAMESPACE="$NAMESPACE" \
    SCENARIO="$SCENARIO" SCENARIO_TIMEOUT_MS=30000 LIFECYCLE_LATE_REPLY_DELAY_MS="${LIFECYCLE_LATE_REPLY_DELAY_MS:-4000}" \
    node "$REVERSE/coatyjs-core-consumer.js" >"$CONSUMER_LOG" 2>&1 &
CONSUMER_PID=$!
wait_for "CoatyJS Call responder readiness" "grep -q '\"state\":\"ready\"' '$CONSUMER_LOG' 2>/dev/null"

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

env "$ENV_FLAG=1" WIRE_BROKER_HOST=127.0.0.1 WIRE_BROKER_PORT=1883 WIRE_NAMESPACE="$NAMESPACE" \
    swift test --filter "$TEST_NAME" 2>&1 | tee "$APPLICATION_LOG.raw"
# Retain only the JSONL state lines the Swift subject printed, matching the
# `application.jsonl` convention used by the other lifecycle runners.
grep -E '^\{"state":' "$APPLICATION_LOG.raw" >"$APPLICATION_LOG" || true
rm -f "$APPLICATION_LOG.raw"

wait "$CONSUMER_PID" || { cat "$CONSUMER_LOG" >&2; exit 1; }
CONSUMER_PID=""
grep -q '"state":"ack"' "$CONSUMER_LOG"

kill "$CAPTURE_PID" >/dev/null 2>&1 || true
CAPTURE_PID=""
sleep 0.3
test -s "$CAPTURE" || { echo "Capture is missing or empty: $CAPTURE" >&2; exit 1; }

echo "Application log retained at $APPLICATION_LOG"
echo "Capture retained at $CAPTURE"
