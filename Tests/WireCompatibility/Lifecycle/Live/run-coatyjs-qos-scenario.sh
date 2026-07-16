#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

SCENARIO="${1:?Usage: run-coatyjs-qos-scenario.sh <qos-0|graceful-deadvertise>}"

RUNTIME="${CONTAINER_RUNTIME:-podman}"
podman() { "$RUNTIME" "$@"; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
LIVE="$ROOT/Tests/WireCompatibility/Live"
HERE="$ROOT/Tests/WireCompatibility/Lifecycle/Live"
REF="$ROOT/Tests/WireCompatibility/ReferenceAgents"
ID="${WIRE_RUN_ID:-$$}"
NET="coaty-lifecycle-qos-$ID"; BROKER="coaty-lifecycle-qos-broker-$ID"
PROBE="coaty-lifecycle-qos-probe-$ID"; SUBJECT="coaty-lifecycle-qos-subject-$ID"
DEV="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
CAPTURE="$OUT/coatyjs-$SCENARIO.jsonl"
APPLICATION_LOG="$OUT/coatyjs-$SCENARIO.application.jsonl"
CAPTURE_READY="$OUT/coatyjs-$SCENARIO.capture-ready"
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-30}"
IDENTITY_ID="44444444-4444-4444-8444-000000000000"
OBJECT_ID="55555555-5555-4555-8555-000000000000"

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

cleanup() {
    podman rm -f "$SUBJECT" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    podman network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
mkdir -p "$OUT"; rm -f "$CAPTURE" "$APPLICATION_LOG" "$CAPTURE_READY"
podman build -t "$DEV" -f "$ROOT/.devcontainer/Dockerfile" "$ROOT/.devcontainer"
podman build -t "$JS" "$REF/coatyjs"
podman network create "$NET" >/dev/null
podman run -d --name "$BROKER" --network "$NET" \
    -v "$LIVE/mosquitto.conf:/etc/mosquitto/wire.conf:ro" \
    "$DEV" mosquitto -c /etc/mosquitto/wire.conf >/dev/null
wait_for "Mosquitto broker readiness" "podman exec '$BROKER' python3 -c 'import socket; socket.create_connection((\"127.0.0.1\",1883),1).close()' >/dev/null 2>&1"
podman run -d --name "$PROBE" --network "$NET" -v "$ROOT:/workspace:ro" -v "$OUT:/artifacts" \
    "$DEV" python3 /workspace/Tests/WireCompatibility/Capture/mqtt_capture.py \
    --host "$BROKER" --topic '#' --producer coatyjs --producer-version 2.4.0 \
    --scenario "$SCENARIO" --output "/artifacts/coatyjs-$SCENARIO.jsonl" \
    --ready-file "/artifacts/${CAPTURE_READY##*/}" >/dev/null
wait_for "capture probe subscription" "test -f '$CAPTURE_READY'"
podman run --name "$SUBJECT" --network "$NET" --entrypoint node \
    -v "$HERE/coatyjs-qos-runner.js:/agent/qos-runner.js:ro" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE="wire-lifecycle-$SCENARIO" \
    -e SCENARIO="$SCENARIO" -e IDENTITY_ID="$IDENTITY_ID" -e OBJECT_ID="$OBJECT_ID" \
    "$JS" /agent/qos-runner.js >"$APPLICATION_LOG" 2>&1
grep -q '"state":"done"' "$APPLICATION_LOG" || { cat "$APPLICATION_LOG" >&2; exit 1; }
podman stop -t 1 "$PROBE" >/dev/null
if [ "$SCENARIO" = "graceful-deadvertise" ]; then
    podman run --rm -v "$ROOT:/workspace:ro" -v "$OUT:/artifacts:ro" "$DEV" python3 \
        /workspace/Tests/WireCompatibility/Lifecycle/Live/verify-coatyjs-qos-scenario.py \
        "$SCENARIO" "/artifacts/coatyjs-$SCENARIO.jsonl" --identity-id "$IDENTITY_ID"
else
    podman run --rm -v "$ROOT:/workspace:ro" -v "$OUT:/artifacts:ro" "$DEV" python3 \
        /workspace/Tests/WireCompatibility/Lifecycle/Live/verify-coatyjs-qos-scenario.py \
        "$SCENARIO" "/artifacts/coatyjs-$SCENARIO.jsonl" --object-id "$OBJECT_ID"
fi
echo "Application log retained at $APPLICATION_LOG"
echo "Capture retained at $CAPTURE"
