#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Containerized lifecycle runner: every broker, probe, proxy, and subject runs
# on one isolated runtime network. It must not depend on host Mosquitto/Swift.
set -euo pipefail

SCENARIO="${1:?Usage: run-lifecycle-network.sh <offline-queueing|reconnect-resubscribe|broker-restart|clean-session>}"
case "$SCENARIO" in
    offline-queueing|reconnect-resubscribe|broker-restart|clean-session) ;;
    *) echo "Unsupported scenario for this runner: $SCENARIO" >&2; exit 64 ;;
esac

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
LIVE="$ROOT/Tests/WireCompatibility/Live"
REF="$ROOT/Tests/WireCompatibility/ReferenceAgents/coatyjs"
TOOL=/tool/dist/index.js
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-lifecycle-$SCENARIO-$RUN_ID"
BROKER="axoloty-lifecycle-broker-$RUN_ID"
PROBE="axoloty-lifecycle-probe-$RUN_ID"
PROXY="axoloty-lifecycle-proxy-$RUN_ID"
SUBJECT="axoloty-lifecycle-subject-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT/.swiftpm-cache}"
BUILD_DIR="${BUILD_DIR:-/tmp/coaty-swift-build/.git/swift-6.3-linux/debug}"
NAMESPACE="wire-lifecycle-$SCENARIO-$RUN_ID"
CAPTURE="$OUT/axoloty-$SCENARIO.jsonl"
CAPTURE_READY="$OUT/axoloty-$SCENARIO.capture-ready"
APPLICATION_LOG="$OUT/axoloty-$SCENARIO.application.jsonl"
RAW_LOG="$OUT/axoloty-$SCENARIO.subject.log"
CONNACK_LOG="$OUT/axoloty-$SCENARIO.connack.jsonl"
PROXY_READY="$OUT/axoloty-$SCENARIO.proxy-ready"

cleanup() {
    runtime logs "$SUBJECT" >"$OUT/subject-container-$SCENARIO.log" 2>&1 || true
    runtime logs "$PROXY" >"$OUT/proxy-container-$SCENARIO.log" 2>&1 || true
    runtime logs "$PROBE" >"$OUT/probe-container-$SCENARIO.log" 2>&1 || true
    runtime logs "$BROKER" >"$OUT/broker-container-$SCENARIO.log" 2>&1 || true
    runtime rm -f "$SUBJECT" "$PROXY" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
mkdir -p "$OUT"
rm -f "$CAPTURE" "$CAPTURE.post-restart" "$CAPTURE_READY" "$APPLICATION_LOG" "$RAW_LOG" "$CONNACK_LOG" "$PROXY_READY"

runtime build -t "$DEV_IMAGE" -f "$ROOT/.devcontainer/Dockerfile" "$ROOT/.devcontainer"
runtime build -t "$JS_IMAGE" "$REF"
runtime network create "$NETWORK" >/dev/null
start_broker() {
    runtime run -d --name "$BROKER" --network "$NETWORK" \
        -v "$LIVE/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
        "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf >/dev/null
}
wait_for() {
    local description="$1" condition="$2" limit=$(( $(date +%s) + ${WIRE_LIFECYCLE_DEADLINE_SECONDS:-600} ))
    while ! eval "$condition"; do
        if [ "$(date +%s)" -ge "$limit" ]; then echo "Timed out waiting for $description" >&2; return 1; fi
        sleep 0.2
    done
}
broker_ready() { runtime exec "$BROKER" python3 -c 'import socket; socket.create_connection(("127.0.0.1",1883),1).close()' >/dev/null 2>&1; }
start_broker
wait_for "Mosquitto broker readiness" broker_ready

start_capture() {
    local output="$1"
    rm -f "$CAPTURE_READY"
    runtime run -d --name "$PROBE" --network "$NETWORK" -v "$ROOT/Tests/WireCompatibility/tool:/tool:ro,Z" -v "$OUT:/artifacts" \
        --entrypoint node --user 0 "$JS_IMAGE" "$TOOL" capture '#' "/artifacts/${output##*/}" \
        --host "$BROKER" --producer coatyswift-modern --producer-version current --scenario "$SCENARIO" \
        --ready-file "/artifacts/${CAPTURE_READY##*/}" >/dev/null
    wait_for "capture subscription" "test -f '$CAPTURE_READY'"
}
start_capture "$CAPTURE"

SUBJECT_HOST="$BROKER"
if [ "$SCENARIO" != "broker-restart" ]; then
    runtime run -d --name "$PROXY" --network "$NETWORK" -v "$ROOT/Tests/WireCompatibility/tool:/tool:ro,Z" -v "$OUT:/artifacts" \
        --entrypoint node --user 0 "$JS_IMAGE" "$TOOL" proxy --listen-port 1883 --broker-host "$BROKER" --broker-port 1883 \
        --control-port 18884 --connack-log "/artifacts/${CONNACK_LOG##*/}" --ready-file "/artifacts/${PROXY_READY##*/}" >/dev/null
    wait_for "TCP proxy readiness" "test -f '$PROXY_READY'"
    SUBJECT_HOST="$PROXY"
fi

test_name="$(case "$SCENARIO" in offline-queueing) echo offlineQueueing ;; reconnect-resubscribe) echo reconnectResubscribe ;; broker-restart) echo brokerRestart ;; clean-session) echo cleanSession ;; esac)"
env_flag="WIRE_LIFECYCLE_$(echo "$SCENARIO" | tr 'a-z-' 'A-Z_')_LIVE"
runtime run -d -t --name "$SUBJECT" --network "$NETWORK" -v "$ROOT:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -v "$BUILD_DIR:/swift-build" -w /workspace \
    -e "$env_flag=1" -e WIRE_BROKER_HOST="$SUBJECT_HOST" -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE="$NAMESPACE" \
    "$DEV_IMAGE" swift test --skip-build --scratch-path /swift-build --cache-path /swiftpm-cache --disable-automatic-resolution --filter "AxolotyLifecycleSubjectTests/$test_name" >/dev/null
subject_reported() { runtime logs "$SUBJECT" 2>&1 >"$RAW_LOG"; grep -q "\"state\":\"$1\"" "$RAW_LOG"; }
wait_for "subject readiness" "subject_reported ready"

publish_probe() {
    runtime run --rm --network "$NETWORK" --entrypoint node \
        -v "$LIVE/coatyjs-advertise-runner.js:/agent/coatyjs-advertise-runner.js:ro" \
        -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE="$NAMESPACE" "$JS_IMAGE" /agent/coatyjs-advertise-runner.js
}
proxy_control() {
    runtime run --rm --network "$NETWORK" -v "$ROOT/Tests/WireCompatibility/tool:/tool:ro,Z" --entrypoint node "$JS_IMAGE" "$TOOL" proxy-control --host "$PROXY" --port 18884 --command "$1"
}
if [ "$SCENARIO" = "broker-restart" ]; then
    runtime rm -f "$PROBE" >/dev/null || true
    runtime rm -f "$BROKER" >/dev/null || true
    wait_for "subject offline transition" "subject_reported offline"
    start_broker
    wait_for "Mosquitto restart" broker_ready
    wait_for "subject reconnect" "subject_reported reconnected"
    start_capture "$CAPTURE.post-restart"
    publish_probe
else
    proxy_control sever
    wait_for "subject offline transition" "subject_reported offline"
    proxy_control restore
    wait_for "subject reconnect" "subject_reported reconnected"
    if [ "$SCENARIO" != "offline-queueing" ]; then publish_probe; fi
fi

runtime wait "$SUBJECT" >/dev/null
runtime logs "$SUBJECT" 2>&1 >"$RAW_LOG"
grep -E '^\{"state":' "$RAW_LOG" >"$APPLICATION_LOG" || true
runtime rm -f "$PROBE" >/dev/null || true
if [ -f "$CAPTURE.post-restart" ]; then cat "$CAPTURE.post-restart" >>"$CAPTURE"; rm -f "$CAPTURE.post-restart"; fi
test -s "$CAPTURE" || { echo "Capture is missing or empty: $CAPTURE" >&2; exit 1; }
test -s "$APPLICATION_LOG" || { echo "Application log is missing or empty: $APPLICATION_LOG" >&2; exit 1; }
echo "Application log retained at $APPLICATION_LOG"
echo "Capture retained at $CAPTURE"
