#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# The modern -> JS direction of IO scenario 1 (Associate generated route):
# Axoloty (modern Swift) is the IO router + IO source under test, and pinned
# CoatyJS 2.4.0 is the IO actor that must decode the Associate, subscribe to
# the generated IOV route, receive the IoValue, and acknowledge at the
# application level. Mirrors Reverse/run-axoloty-advertise.sh.
#
# The JS -> modern direction (CoatyJS source -> Axoloty actor) is not driven
# by this runner: Axoloty's `handleAssociate` force-unwraps the optional
# `isExternalRoute` on the actor path (CommunicationManager.swift:557), and
# CoatyJS 2.4.0 never serializes `isExternalRoute`, so an Axoloty actor would
# trap on a CoatyJS Associate. That decode fact is locked in offline by
# `AxolotyIoAssociateTests.associateEventDecodesCoatyJSPayloadWithoutIsExternalRoute`;
# the live JS -> modern direction is recorded as a defect in the decisions doc.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
IO_DIR="$ROOT_DIR/Tests/Support/WireCompatibility/IO"
LIVE_DIR="$ROOT_DIR/Tests/Support/WireCompatibility/Live"
REFERENCE_DIR="$ROOT_DIR/Tests/Support/WireCompatibility/ReferenceAgents"
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-wire-io-assoc-$RUN_ID"
BROKER="axoloty-wire-io-assoc-broker-$RUN_ID"
ACTOR="axoloty-wire-io-assoc-actor-$RUN_ID"
PROBE="axoloty-wire-io-assoc-probe-$RUN_ID"
DEV_IMAGE="${DEV_IMAGE:-localhost/axoloty-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
ACTOR_LOG=$(mktemp)
OUTPUT_DIR="${WIRE_OUTPUT_DIR:-$ROOT_DIR/.testing/wire/io/associate}"
ACK_BASENAME="io-associate-$RUN_ID.peer-ack.json"
ACK_DIR="$OUTPUT_DIR/peer-acks"
ACK_FILE="$ACK_DIR/$ACK_BASENAME"
ACK_TOKEN="${RUN_ID}-io-associate"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/axoloty-wire-module-cache

cleanup() {
    runtime rm -f "$ACTOR" "$PROBE" "$BROKER" >/dev/null 2>&1 || true
    runtime network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -f "$ACTOR_LOG"
}
trap cleanup EXIT INT TERM
mkdir -p "$OUTPUT_DIR" "$ACK_DIR"
chmod 0777 "$ACK_DIR"
rm -f "$OUTPUT_DIR/io-associate.jsonl" "$ACK_FILE"

runtime build -t "$DEV_IMAGE" -f "$ROOT_DIR/.devcontainer/Dockerfile" "$ROOT_DIR"
runtime build -t "$JS_IMAGE" "$REFERENCE_DIR/coatyjs"
runtime network create "$NETWORK" >/dev/null
runtime run -d --name "$BROKER" --network "$NETWORK" \
    -v "$LIVE_DIR/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
    "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf >/dev/null

for _ in $(seq 1 30); do
    runtime exec "$BROKER" node -e 'const s=require("node:net").createConnection({host:"127.0.0.1",port:1883},()=>s.end()); s.on("error",()=>process.exit(1))' >/dev/null 2>&1 && break
    sleep 0.2
done

runtime run -d --name "$PROBE" --network "$NETWORK" \
    -v "$ROOT_DIR:/workspace:ro" -v "$OUTPUT_DIR:/artifacts" \
    --entrypoint node --user 0 "$JS_IMAGE" /workspace/Tests/Support/WireCompatibility/tool/dist/index.js capture '#' /artifacts/io-associate.jsonl \
    --host "$BROKER" --producer coatyswift-modern --producer-version current \
    --scenario io-associate >/dev/null
sleep 0.5

# CoatyJS actor first: it subscribes to ASC-<context> on start, so it must be
# ready before Axoloty publishes the Associate. SCENARIO_TIMEOUT_MS is generous
# because the Axoloty producer's in-container cold build can take ~50s before
# it publishes (see Task 0 baseline: ~54s to ready).
runtime run -d --name "$ACTOR" --network "$NETWORK" --entrypoint node \
    -v "$IO_DIR/coatyjs-io-runner.js:/agent/coatyjs-io-runner.js:ro,Z" \
    -v "$ACK_DIR:/peer-acks" \
    -e BROKER_URL="mqtt://$BROKER:1883" -e COATY_NAMESPACE=wire-compat-v1 \
    -e ROLE=actor -e IO_EXPECTED_VALUES=1 -e WIRE_SCENARIO=io-associate \
    -e WIRE_PEER_ACK_FILE="/peer-acks/$ACK_BASENAME" -e WIRE_PEER_ACK_TOKEN="$ACK_TOKEN" \
    -e SCENARIO_TIMEOUT_MS=600000 \
    "$JS_IMAGE" /agent/coatyjs-io-runner.js >/dev/null

for _ in $(seq 1 60); do
    runtime logs "$ACTOR" >"$ACTOR_LOG" 2>&1
    grep -q '"state":"ready"' "$ACTOR_LOG" && break
    sleep 0.5
done
grep -q '"state":"ready"' "$ACTOR_LOG" || { cat "$ACTOR_LOG" >&2; exit 1; }

# Axoloty is the producer: it associates source+actor on a generated route and
# publishes one JSON IoValue. Disabled outside the live gate.
runtime run --rm --network "$NETWORK" -v "$ROOT_DIR:/workspace" -v "$OUTPUT_DIR:/artifacts" -v "$SPM_CACHE_DIR:/swiftpm-cache" -w /workspace \
    -e WIRE_IO_MODERN_TO_JS_LIVE=1 -e WIRE_BROKER_HOST="$BROKER" \
    -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE=wire-compat-v1 \
    -e WIRE_PEER_ACK_FILE="/artifacts/peer-acks/$ACK_BASENAME" -e WIRE_PEER_ACK_TOKEN="$ACK_TOKEN" \
    -e "SWIFTPM_MODULECACHE_OVERRIDE=$SWIFTPM_MODULECACHE_OVERRIDE" \
    "$DEV_IMAGE" swift test -Xswiftc -module-cache-path -Xswiftc "$SWIFTPM_MODULECACHE_OVERRIDE" \
    --cache-path /swiftpm-cache --disable-automatic-resolution --filter AxolotyIoAssociateTests

sleep 0.5
runtime stop -t 1 "$PROBE" >/dev/null || true

runtime wait "$ACTOR" >/dev/null
runtime logs "$ACTOR" >"$ACTOR_LOG" 2>&1
cat "$ACTOR_LOG"
grep -q '"state":"ack"' "$ACTOR_LOG"
test -s "$ACK_FILE"
echo "PASS: Axoloty IO Associate + IoValue decoded by CoatyJS 2.4.0"
