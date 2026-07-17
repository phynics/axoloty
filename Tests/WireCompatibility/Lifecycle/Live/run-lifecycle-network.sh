#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Native live runner for the network-failure lifecycle scenarios:
# offline-queueing, reconnect-resubscribe, broker-restart, clean-session.
#
# Axoloty (modern Swift) is the live subject. For the proxy scenarios its
# MQTT connection runs through tcp_proxy.py so this script can sever and
# restore connectivity at the TCP level while the passive capture probe
# (connected to the broker directly) keeps observing the wire. For
# broker-restart the subject connects directly and the broker process
# itself is stopped and restarted. The post-reconnect probe for the
# subscription scenarios is a genuine pinned CoatyJS 2.4.0 Advertise
# (coatyjs-advertise-runner.js), so re-subscription is proven by a decoded
# cross-implementation event, not a loopback publish.
set -euo pipefail

SCENARIO="${1:?Usage: run-lifecycle-network.sh <offline-queueing|reconnect-resubscribe|broker-restart|clean-session>}"
case "$SCENARIO" in
    offline-queueing|reconnect-resubscribe|broker-restart|clean-session) ;;
    *) echo "Unsupported scenario for this runner: $SCENARIO" >&2; exit 64 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
HERE="$ROOT/Tests/WireCompatibility/Lifecycle/Live"
LIVE="$ROOT/Tests/WireCompatibility/Live"
REF="$ROOT/Tests/WireCompatibility/ReferenceAgents/coatyjs"
MOSQUITTO="${MOSQUITTO_BIN:-/opt/homebrew/opt/mosquitto/sbin/mosquitto}"
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
RUN_ID="${WIRE_RUN_ID:-$$}"
NAMESPACE="wire-lifecycle-$SCENARIO-$RUN_ID"
CAPTURE="$OUT/axoloty-$SCENARIO.jsonl"
CAPTURE_READY="$OUT/axoloty-$SCENARIO.capture-ready"
APPLICATION_LOG="$OUT/axoloty-$SCENARIO.application.jsonl"
CONNACK_LOG="$OUT/axoloty-$SCENARIO.connack.jsonl"
PROXY_READY="$OUT/axoloty-$SCENARIO.proxy-ready"
PROXY_PORT=18883
CONTROL_PORT=18884
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-60}"

MOSQUITTO_PID=""
CAPTURE_PID=""
PROXY_PID=""
SUBJECT_PID=""
cleanup() {
    [ -n "$SUBJECT_PID" ] && kill "$SUBJECT_PID" >/dev/null 2>&1 || true
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" >/dev/null 2>&1 || true
    [ -n "$CAPTURE_PID" ] && kill "$CAPTURE_PID" >/dev/null 2>&1 || true
    [ -n "$MOSQUITTO_PID" ] && kill "$MOSQUITTO_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

mkdir -p "$OUT"
rm -f "$CAPTURE" "$CAPTURE_READY" "$APPLICATION_LOG" "$APPLICATION_LOG.raw" \
    "$CONNACK_LOG" "$PROXY_READY"

if ! command -v "$MOSQUITTO" >/dev/null 2>&1; then
    echo "mosquitto binary not found at $MOSQUITTO (set MOSQUITTO_BIN)" >&2
    exit 1
fi

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
proxy_command() {
    python3 - "$1" <<'PY'
import socket, sys
with socket.create_connection(("127.0.0.1", 18884), 5) as sock:
    sock.sendall((sys.argv[1] + "\n").encode())
    reply = sock.makefile().readline().strip()
if reply != "ok":
    raise SystemExit(f"proxy control replied {reply!r}")
PY
}
broker_ready() {
    python3 -c 'import socket; socket.create_connection(("127.0.0.1",1883),1).close()' >/dev/null 2>&1
}
start_broker() {
    "$MOSQUITTO" -c "$LIVE/mosquitto.conf" >>"$OUT/mosquitto-$SCENARIO.log" 2>&1 &
    MOSQUITTO_PID=$!
    wait_for "Mosquitto broker readiness" broker_ready
}
start_capture() {
    rm -f "$CAPTURE_READY"
    python3 "$ROOT/Tests/WireCompatibility/Capture/mqtt_capture.py" \
        --host 127.0.0.1 --topic '#' --producer coatyswift-modern --producer-version current \
        --scenario "$SCENARIO" --output "$1" --ready-file "$CAPTURE_READY" \
        >>"$OUT/capture-$SCENARIO.log" 2>&1 &
    CAPTURE_PID=$!
    wait_for "capture subscription" "test -f '$CAPTURE_READY'"
}
subject_reported() {
    grep -q "\"state\":\"$1\"" "$APPLICATION_LOG.raw" 2>/dev/null
}
publish_coatyjs_probe() {
    NODE_PATH="$REF/node_modules" BROKER_URL="mqtt://127.0.0.1:1883" COATY_NAMESPACE="$NAMESPACE" \
        node "$LIVE/coatyjs-advertise-runner.js" >"$OUT/coatyjs-$SCENARIO.probe.log" 2>&1
}

# Build up front so the subject-readiness deadline below measures the
# scenario, not compilation.
(cd "$ROOT" && swift build --build-tests >"$OUT/build-$SCENARIO.log" 2>&1)

start_broker
start_capture "$CAPTURE"

SUBJECT_PORT=1883
if [ "$SCENARIO" != "broker-restart" ]; then
    python3 "$HERE/tcp_proxy.py" --listen-port "$PROXY_PORT" --broker-port 1883 \
        --control-port "$CONTROL_PORT" --connack-log "$CONNACK_LOG" --ready-file "$PROXY_READY" \
        >"$OUT/proxy-$SCENARIO.log" 2>&1 &
    PROXY_PID=$!
    wait_for "TCP proxy readiness" "test -f '$PROXY_READY'"
    SUBJECT_PORT=$PROXY_PORT
fi

TEST_NAME="AxolotyLifecycleSubjectTests/$(
    case "$SCENARIO" in
        offline-queueing) echo offlineQueueing ;;
        reconnect-resubscribe) echo reconnectResubscribe ;;
        broker-restart) echo brokerRestart ;;
        clean-session) echo cleanSession ;;
    esac
)"
ENV_FLAG="WIRE_LIFECYCLE_$(echo "$SCENARIO" | tr 'a-z-' 'A-Z_')_LIVE"

# `script` gives the subject a pseudo-TTY: swift-test's output relay is
# block-buffered when piped, which would hold every JSONL state line until
# process exit -- after the sever/restore points this script must react to.
env "$ENV_FLAG=1" WIRE_BROKER_HOST=127.0.0.1 WIRE_BROKER_PORT="$SUBJECT_PORT" \
    WIRE_NAMESPACE="$NAMESPACE" \
    script -q "$APPLICATION_LOG.raw" swift test --filter "$TEST_NAME" >/dev/null 2>&1 &
SUBJECT_PID=$!

wait_for "subject readiness" "subject_reported ready"

if [ "$SCENARIO" = "broker-restart" ]; then
    # A real broker outage: the capture probe's connection dies with it, so
    # a fresh capture is attached once the broker is back and its records
    # are appended to the same retained artifact.
    kill "$CAPTURE_PID" >/dev/null 2>&1 || true
    kill "$MOSQUITTO_PID" >/dev/null 2>&1; wait "$MOSQUITTO_PID" 2>/dev/null || true
    MOSQUITTO_PID=""
    wait_for "subject offline transition" "subject_reported offline"
    start_broker
    wait_for "subject reconnect" "subject_reported reconnected"
    start_capture "$CAPTURE.post-restart"
    publish_coatyjs_probe
else
    proxy_command sever
    wait_for "subject offline transition" "subject_reported offline"
    proxy_command restore
    wait_for "subject reconnect" "subject_reported reconnected"
    if [ "$SCENARIO" != "offline-queueing" ]; then
        publish_coatyjs_probe
    fi
fi

if ! wait "$SUBJECT_PID"; then
    SUBJECT_PID=""
    cat "$APPLICATION_LOG.raw" >&2
    exit 1
fi
SUBJECT_PID=""

grep -E '^\{"state":' "$APPLICATION_LOG.raw" >"$APPLICATION_LOG" || true
rm -f "$APPLICATION_LOG.raw"

kill "$CAPTURE_PID" >/dev/null 2>&1 || true
CAPTURE_PID=""
sleep 0.3
if [ -f "$CAPTURE.post-restart" ]; then
    cat "$CAPTURE.post-restart" >>"$CAPTURE"
    rm -f "$CAPTURE.post-restart"
fi
test -s "$CAPTURE" || { echo "Capture is missing or empty: $CAPTURE" >&2; exit 1; }

if [ "$SCENARIO" = "clean-session" ]; then
    python3 "$HERE/verify-lifecycle-network.py" "$SCENARIO" "$CAPTURE" "$APPLICATION_LOG" \
        --connack-log "$CONNACK_LOG"
else
    python3 "$HERE/verify-lifecycle-network.py" "$SCENARIO" "$CAPTURE" "$APPLICATION_LOG"
fi

echo "Application log retained at $APPLICATION_LOG"
echo "Capture retained at $CAPTURE"
