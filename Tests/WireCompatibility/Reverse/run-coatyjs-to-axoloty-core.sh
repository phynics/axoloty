#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# JS -> modern core interoperability: CoatyJS publishes a scenario only after
# Axoloty has acquired its subscription and signaled via a file. Request/
# response scenarios additionally require CoatyJS to validate Axoloty's reply.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LIVE_DIR="$ROOT_DIR/Tests/WireCompatibility/Live"
REFERENCE_DIR="$ROOT_DIR/Tests/WireCompatibility/ReferenceAgents"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-wire-js-to-modern-core-$RUN_ID"
BROKER="axoloty-wire-js-to-modern-core-broker-$RUN_ID"
CONSUMER_READY_TIMEOUT_SECONDS="${WIRE_CONSUMER_READY_TIMEOUT_SECONDS:-180}"
DEV_IMAGE="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
CACHE_NAMESPACE="${CACHE_NAMESPACE:-swift-6.3-linux}"
REPOSITORY_NAME="${REPOSITORY_NAME:-$(git -C "$ROOT_DIR" rev-parse --git-common-dir | sed 's|/.git$||' | xargs basename)}"
BUILD_DIR="${BUILD_DIR:-/tmp/coaty-swift-build/$REPOSITORY_NAME/$CACHE_NAMESPACE/debug}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/$CACHE_NAMESPACE}"
SIGNAL_DIR=$(mktemp -d)
CONSUMER=""

cleanup() {
    runtime rm -f "$CONSUMER" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$SIGNAL_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$BUILD_DIR" "$SPM_CACHE_DIR"
runtime build -t "$DEV_IMAGE" -f "$ROOT_DIR/.devcontainer/Dockerfile" "$ROOT_DIR/.devcontainer"
runtime build -t "$JS_IMAGE" "$REFERENCE_DIR/coatyjs"
runtime network create "$NETWORK" >/dev/null
runtime run -d --name "$BROKER" --network "$NETWORK" \
    -v "$LIVE_DIR/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
    "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf >/dev/null

for _ in $(seq 1 30); do
    runtime exec "$BROKER" bash -c '>/dev/tcp/127.0.0.1/1883' >/dev/null 2>&1 && break
    sleep 0.2
done
runtime exec "$BROKER" bash -c '>/dev/tcp/127.0.0.1/1883' >/dev/null

SCENARIOS="${WIRE_SCENARIOS:-deadvertise channel}"
for scenario in $SCENARIOS; do
    case "$scenario" in
        deadvertise|channel|discover-resolve|query-retrieve|update-complete|call-return) ;;
        *) echo "Unsupported JS -> modern core scenario: $scenario" >&2; exit 64 ;;
    esac

    CONSUMER="axoloty-wire-js-to-modern-core-consumer-$scenario-$RUN_ID"
    ready_file="$SIGNAL_DIR/$scenario.ready"
    consumer_log="$SIGNAL_DIR/$scenario.log"
    rm -f "$ready_file"
    case "$scenario" in
        deadvertise|channel)
            test_filter="AxolotyCoreConsumerTests"
            ;;
        discover-resolve|query-retrieve)
            test_filter="AxolotyCoreRequestConsumerTests"
            ;;
        update-complete)
            test_filter="AxolotyUpdateCompleteConsumerTests"
            ;;
        call-return)
            test_filter="AxolotyCallReturnConsumerTests"
            ;;
    esac

    runtime run -d --name "$CONSUMER" --network "$NETWORK" \
        -v "$ROOT_DIR:/workspace" -v "$BUILD_DIR:/workspace/.build" \
        -v "$SPM_CACHE_DIR:/workspace/.swiftpm-cache" -v "$SIGNAL_DIR:/signals" -w /workspace \
        -e WIRE_JS_TO_MODERN_LIVE=1 -e WIRE_SCENARIO="$scenario" \
        -e WIRE_BROKER_HOST="$BROKER" -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE=wire-compat-v1 \
        -e WIRE_READY_FILE="/signals/$scenario.ready" \
        "$DEV_IMAGE" swift test --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
        --filter "$test_filter" >/dev/null

    for _ in $(seq 1 "$CONSUMER_READY_TIMEOUT_SECONDS"); do
        test -s "$ready_file" && break
        sleep 1
    done
    if ! test -s "$ready_file"; then
        runtime logs "$CONSUMER" >&2 || true
        echo "Axoloty $scenario consumer never reported readiness" >&2
        exit 1
    fi

    case "$scenario" in
        deadvertise|channel)
            requester_script="/agent/coatyjs-core-runner.js"
            requester_mount="$LIVE_DIR/coatyjs-core-runner.js:/agent/coatyjs-core-runner.js:ro"
            ;;
        discover-resolve|query-retrieve)
            requester_script="/agent/coatyjs-core-requester.js"
            requester_mount="$ROOT_DIR/Tests/WireCompatibility/Reverse/coatyjs-core-requester.js:/agent/coatyjs-core-requester.js:ro"
            ;;
        update-complete|call-return)
            requester_script="/agent/coatyjs-to-modern-requester.js"
            requester_mount="$ROOT_DIR/Tests/WireCompatibility/Reverse/coatyjs-to-modern-requester.js:/agent/coatyjs-to-modern-requester.js:ro"
            ;;
    esac

    requester_log="$SIGNAL_DIR/$scenario.requester.log"
    runtime run --rm --network "$NETWORK" --entrypoint node \
        -v "$requester_mount" \
        -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE=wire-compat-v1 \
        -e SCENARIO="$scenario" -e SCENARIO_SETTLE_MS=1500 \
        "$JS_IMAGE" "$requester_script" >"$requester_log" 2>&1

    if ! runtime wait "$CONSUMER" >/dev/null; then
        runtime logs "$CONSUMER" >&2 || true
        exit 1
    fi
    runtime logs "$CONSUMER" >"$consumer_log" 2>&1
    runtime rm "$CONSUMER" >/dev/null
    CONSUMER=""
    if [[ "$scenario" == "deadvertise" || "$scenario" == "channel" ]]; then
        grep -q "\"state\":\"ack\",\"scenario\":\"$scenario\"" "$consumer_log"
    else
        grep -q "received-" "$requester_log"
    fi
    echo "PASS: CoatyJS $scenario decoded by Axoloty (modern Swift)"
done
