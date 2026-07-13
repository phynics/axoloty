#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
podman() { "$RUNTIME" "$@"; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
LIVE="$ROOT/Tests/WireCompatibility/Live"
HERE="$ROOT/Tests/WireCompatibility/Lifecycle/Live"
REF="$ROOT/Tests/WireCompatibility/ReferenceAgents"
ID="${WIRE_RUN_ID:-$$}"
NET="coaty-lifecycle-$ID"; BROKER="coaty-lifecycle-broker-$ID"
PROBE="coaty-lifecycle-probe-$ID"; SUBJECT="coaty-lifecycle-subject-$ID"
DEV="${DEV_IMAGE:-localhost/coatyswift-dev:latest}"
JS="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"

cleanup() {
    podman rm -f "$SUBJECT" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    podman network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
mkdir -p "$OUT"; rm -f "$OUT/coatyjs-last-will.jsonl"
podman build -t "$DEV" -f "$ROOT/.devcontainer/Dockerfile" "$ROOT/.devcontainer"
podman build -t "$JS" "$REF/coatyjs"
podman network create "$NET" >/dev/null
podman run -d --name "$BROKER" --network "$NET" \
    -v "$LIVE/mosquitto.conf:/etc/mosquitto/wire.conf:ro" \
    "$DEV" mosquitto -c /etc/mosquitto/wire.conf >/dev/null
for _ in $(seq 1 30); do
    podman exec "$BROKER" python3 -c 'import socket; socket.create_connection(("127.0.0.1",1883),1).close()' \
        >/dev/null 2>&1 && break
    sleep 0.2
done
podman exec "$BROKER" python3 -c 'import socket; socket.create_connection(("127.0.0.1",1883),1).close()'
podman run -d --name "$PROBE" --network "$NET" -v "$ROOT:/workspace:ro" -v "$OUT:/artifacts" \
    "$DEV" python3 /workspace/Tests/WireCompatibility/Capture/mqtt_capture.py \
    --host "$BROKER" --topic '#' --producer coatyjs --producer-version 2.4.0 \
    --scenario unexpected-disconnect-last-will --output /artifacts/coatyjs-last-will.jsonl >/dev/null
sleep 0.5
podman run -d --name "$SUBJECT" --network "$NET" --entrypoint node \
    -v "$HERE/coatyjs-last-will-runner.js:/agent/last-will.js:ro" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE=wire-lifecycle-last-will \
    "$JS" /agent/last-will.js >/dev/null
for _ in $(seq 1 50); do
    podman logs "$SUBJECT" 2>&1 | grep -q '"state":"ready"' && break
    sleep 0.2
done
podman logs "$SUBJECT" 2>&1 | grep -q '"state":"ready"'
sleep 0.5
podman kill --signal KILL "$SUBJECT" >/dev/null
sleep 1
podman stop -t 1 "$PROBE" >/dev/null
podman run --rm -v "$ROOT:/workspace:ro" -v "$OUT:/artifacts:ro" "$DEV" python3 \
    /workspace/Tests/WireCompatibility/Lifecycle/Live/verify-coatyjs-last-will.py \
    /artifacts/coatyjs-last-will.jsonl
echo "Capture retained at $OUT/coatyjs-last-will.jsonl"
