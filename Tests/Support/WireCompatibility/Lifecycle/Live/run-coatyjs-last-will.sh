#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
podman() { command "$RUNTIME" "$@"; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
LIVE="$ROOT/Tests/Support/WireCompatibility/Live"
HERE="$ROOT/Tests/Support/WireCompatibility/Lifecycle/Live"
ID="${WIRE_RUN_ID:-$$}"
NET="coaty-lifecycle-$ID"; BROKER="coaty-lifecycle-broker-$ID"
PROBE="coaty-lifecycle-probe-$ID"; SUBJECT="coaty-lifecycle-subject-$ID"
DEV="${DEV_IMAGE:-localhost/axoloty-dev:latest}"
JS="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
CAPTURE="$OUT/coatyjs-last-will.jsonl"
APPLICATION_LOG="$OUT/coatyjs-last-will.application.jsonl"
CAPTURE_READY="$OUT/coatyjs-last-will.capture-ready"
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-30}"
RUNTIME_LABELS=(
    --label "io.axoloty.managed-by=${WIRE_RUNTIME_MANAGED_BY:-axoloty-wire-lifecycle}"
    --label "io.axoloty.run-id=${WIRE_RUNTIME_RUN_ID:-$ID}"
    --label "io.axoloty.scenario=${WIRE_RUNTIME_SCENARIO:-unexpected-disconnect-last-will}"
)

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
podman network create "$NET" "${RUNTIME_LABELS[@]}" >/dev/null
podman run -d --name "$BROKER" --network "$NET" "${RUNTIME_LABELS[@]}" \
    -v "$LIVE/mosquitto.conf:/etc/mosquitto/wire.conf:ro" \
    "$DEV" mosquitto -c /etc/mosquitto/wire.conf >/dev/null
wait_for "Mosquitto broker readiness" "podman exec '$BROKER' node -e 'const s=require(\"node:net\").createConnection({host:\"127.0.0.1\",port:1883},()=>s.end()); s.on(\"error\",()=>process.exit(1))' >/dev/null 2>&1"
podman run -d --name "$PROBE" --network "$NET" -v "$ROOT:/workspace:ro" -v "$OUT:/artifacts" \
    --entrypoint node --user 0 "${RUNTIME_LABELS[@]}" "$JS" /workspace/Tests/Support/WireCompatibility/tool/dist/index.js capture '#' /artifacts/coatyjs-last-will.jsonl \
    --host "$BROKER" --producer coatyjs --producer-version 2.4.0 \
    --scenario unexpected-disconnect-last-will \
    --ready-file "/artifacts/${CAPTURE_READY##*/}" >/dev/null
wait_for "capture probe subscription" "test -f '$CAPTURE_READY'"
podman run -d --name "$SUBJECT" --network "$NET" --entrypoint node "${RUNTIME_LABELS[@]}" \
    -v "$HERE/coatyjs-last-will-runner.js:/agent/last-will.js:ro" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE=wire-lifecycle-last-will \
    "$JS" /agent/last-will.js >/dev/null
wait_for "CoatyJS application readiness" "podman logs '$SUBJECT' 2>&1 | grep -q '\"state\":\"ready\"'"
podman logs "$SUBJECT" >"$APPLICATION_LOG" 2>&1
wait_for "identity advertisement capture" "grep -q '/ADV:' '$CAPTURE'"
podman kill --signal KILL "$SUBJECT" >/dev/null
wait_for "broker-issued last will capture" "grep -q '/DAD/' '$CAPTURE'"
podman stop -t 1 "$PROBE" >/dev/null
test -s "$CAPTURE" || { echo "Capture is missing or empty: $CAPTURE" >&2; exit 1; }
echo "Application log retained at $APPLICATION_LOG"
echo "Capture retained at $CAPTURE"
