#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Modern → legacy live runner. Axoloty (modern Swift) produces events; pinned
# CoatySwift 2.4.0 acts as a consumer/responder via the macOS runner. This
# script orchestrates the broker, capture probe, Axoloty producer (Swift test),
# and legacy consumer (macOS runner).
#
# Requirements: macOS with Xcode, Mosquitto, and the legacy runner prepared
# (Tests/WireCompatibility/Legacy/macOS-runner/prepare.sh). This script runs
# natively on macOS — CoatySwift 2.4.0 cannot be containerized.
#
# Usage: run-modern-to-legacy.sh <scenario>
# Scenarios: advertise deadvertise channel discover query call
set -euo pipefail

SCENARIO="${1:?Usage: run-modern-to-legacy.sh <advertise|deadvertise|channel|discover|query|call>}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LEGACY_RUNNER="$ROOT/Tests/WireCompatibility/Legacy/macOS-runner/run.sh"
SOURCE_COMMIT="20a97b29832758fb771ac79fd5f7ae36cff69403"
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
RUN_ID="${WIRE_RUN_ID:-$$}"
NAMESPACE="wire-modern-to-legacy-$SCENARIO-$RUN_ID"
CAPTURE="$OUT/modern-to-legacy-$SCENARIO.jsonl"
CAPTURE_READY="$OUT/modern-to-legacy-$SCENARIO.capture-ready"
CONSUMER_LOG="$OUT/legacy-consumer-$SCENARIO.log"
APPLICATION_LOG="$OUT/axoloty-producer-$SCENARIO.application.jsonl"
MOSQUITTO="${MOSQUITTO_BIN:-$(command -v mosquitto 2>/dev/null || echo /opt/homebrew/opt/mosquitto/sbin/mosquitto)}"
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-60}"

# Map scenario to the legacy runner consumer scenario and the Axoloty test
# filter/env flag.
case "$SCENARIO" in
    advertise)
        LEGACY_SCENARIO="consume-advertise"
        AXOLOTY_TEST="AxolotyCoreProducerTests/advertiseForLegacyConsumer"
        AXOLOTY_ENV="WIRE_LEGACY_CONSUMER_ADVERTISE_LIVE"
        ;;
    deadvertise)
        LEGACY_SCENARIO="consume-deadvertise"
        AXOLOTY_TEST="AxolotyCoreProducerTests/deadvertiseForLegacyConsumer"
        AXOLOTY_ENV="WIRE_LEGACY_CONSUMER_DEADVERTISE_LIVE"
        ;;
    channel)
        LEGACY_SCENARIO="consume-channel"
        AXOLOTY_TEST="AxolotyCoreProducerTests/channelForLegacyConsumer"
        AXOLOTY_ENV="WIRE_LEGACY_CONSUMER_CHANNEL_LIVE"
        ;;
    discover)
        LEGACY_SCENARIO="respond-discover"
        AXOLOTY_TEST="AxolotyCoreProducerTests/discoverForLegacyResponder"
        AXOLOTY_ENV="WIRE_LEGACY_CONSUMER_DISCOVER_LIVE"
        ;;
    query)
        LEGACY_SCENARIO="respond-query"
        AXOLOTY_TEST="AxolotyCoreProducerTests/queryForLegacyResponder"
        AXOLOTY_ENV="WIRE_LEGACY_CONSUMER_QUERY_LIVE"
        ;;
    call)
        LEGACY_SCENARIO="respond-call"
        AXOLOTY_TEST="AxolotyCoreProducerTests/callForLegacyResponder"
        AXOLOTY_ENV="WIRE_LEGACY_CONSUMER_CALL_LIVE"
        ;;
    *)
        echo "Unsupported scenario: $SCENARIO" >&2
        exit 64
        ;;
esac

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

# Start broker.
"$MOSQUITTO" -c "$ROOT/Tests/WireCompatibility/Live/mosquitto.conf" >"$OUT/mosquitto-modern-to-legacy-$SCENARIO.log" 2>&1 &
MOSQUITTO_PID=$!

wait_for() {
    local description="$1" condition="$2" limit=$(( $(date +%s) + DEADLINE_SECONDS ))
    while ! eval "$condition"; do
        if [ "$(date +%s)" -ge "$limit" ]; then
            echo "Timed out waiting for $description after ${DEADLINE_SECONDS}s" >&2
            return 1
        fi
        sleep 0.1
    done
}
wait_for "Mosquitto broker readiness" "node -e 'const s=require(\"net\").createConnection({host:\"127.0.0.1\",port:1883},()=>{s.end();process.exit(0)});s.on(\"error\",()=>process.exit(1))' >/dev/null 2>&1"

# Start capture probe.
node "$ROOT/Tests/WireCompatibility/tool/dist/index.js" capture '#' "$CAPTURE" \
    --host 127.0.0.1 --producer axoloty-modern --producer-version current \
    --scenario "modern-to-legacy-$SCENARIO" --ready-file "$CAPTURE_READY" \
    >"$OUT/capture-modern-to-legacy-$SCENARIO.log" 2>&1 &
CAPTURE_PID=$!
wait_for "capture subscription" "test -f '$CAPTURE_READY'"

# Start legacy consumer first (it subscribes before the producer publishes).
"$LEGACY_RUNNER" \
    --broker-host 127.0.0.1 --broker-port 1883 \
    --scenario "$LEGACY_SCENARIO" --source-commit "$SOURCE_COMMIT" \
    >"$CONSUMER_LOG" 2>&1 &
CONSUMER_PID=$!
wait_for "legacy consumer readiness" "grep -q '\"state\":\"ready\"' '$CONSUMER_LOG' 2>/dev/null"

# Run Axoloty producer (Swift test).
env "$AXOLOTY_ENV=1" WIRE_BROKER_HOST=127.0.0.1 WIRE_BROKER_PORT=1883 WIRE_NAMESPACE="$NAMESPACE" \
    swift test --filter "$AXOLOTY_TEST" 2>&1 | tee "$APPLICATION_LOG.raw"
grep -E '^\{"state":' "$APPLICATION_LOG.raw" >"$APPLICATION_LOG" || true
rm -f "$APPLICATION_LOG.raw"

# Verify legacy consumer observed the event.
wait "$CONSUMER_PID" || { cat "$CONSUMER_LOG" >&2; exit 1; }
CONSUMER_PID=""
grep -q '"state":"observed' "$CONSUMER_LOG" || {
    echo "Legacy consumer did not observe the event; see $CONSUMER_LOG" >&2
    exit 1
}

# Verify capture.
kill "$CAPTURE_PID" >/dev/null 2>&1 || true
CAPTURE_PID=""
sleep 0.3
test -s "$CAPTURE" || { echo "Capture is missing or empty: $CAPTURE" >&2; exit 1; }

echo "Application log retained at $APPLICATION_LOG"
echo "Consumer log retained at $CONSUMER_LOG"
echo "Capture retained at $CAPTURE"
