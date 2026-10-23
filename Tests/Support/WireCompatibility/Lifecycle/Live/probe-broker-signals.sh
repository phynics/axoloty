#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Fail before compiling subjects if this host cannot stop the isolated broker.
# Keep UID and security-label evidence together with the actual signal result.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
RUNTIME="${CONTAINER_RUNTIME:-podman}"
DEV_IMAGE="${DEV_IMAGE:-localhost/axoloty-dev:latest}"
BROKER_ID=""
runtime() { timeout 15s "$RUNTIME" "$@"; }
cleanup() {
    local result=$?
    trap - EXIT
    if [ -n "$BROKER_ID" ]; then
        runtime logs "$BROKER_ID" || true
        if [ "$(runtime inspect "$BROKER_ID" --format '{{.State.Status}}')" = running ]; then
            runtime kill --signal KILL "$BROKER_ID" || true
        fi
        runtime rm "$BROKER_ID" || true
    fi
    exit "$result"
}
trap cleanup EXIT
"$RUNTIME" version --format '{{.Client.Version}}' || true
BROKER_ID=$(runtime run -d --user mosquitto --network none \
    --label io.axoloty.managed-by=axoloty-wire-lifecycle \
    --label "io.axoloty.run-id=${WIRE_RUN_ID:-broker-signal-probe-$$}" \
    --label io.axoloty.scenario=broker-signal-probe \
    -v "$ROOT/Tests/Support/WireCompatibility/Live/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
    "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf)
runtime inspect "$BROKER_ID" --format 'user={{.Config.User}} apparmor={{.AppArmorProfile}} pid={{.State.Pid}}'
ready=0
for attempt in {1..30}; do
    if runtime exec --user mosquitto "$BROKER_ID" node -e 'const s=require("node:net").createConnection({port:1883,host:"127.0.0.1"},()=>s.end());s.on("error",()=>process.exit(1))'; then
        ready=1
        break
    fi
    sleep 0.2
done
[ "$ready" -eq 1 ] || { echo 'Broker signal probe never became ready' >&2; exit 1; }
runtime exec --user mosquitto "$BROKER_ID" sh -c '
    id
    grep -E "^(Name|Uid|Gid|CapEff|NoNewPrivs):" /proc/1/status
    printf "broker security profile: "
    cat /proc/1/attr/current 2>/dev/null || true
    printf "signal sender security profile: "
    cat /proc/self/attr/current 2>/dev/null || true
    kill -TERM 1
'
runtime wait "$BROKER_ID"
[ "$(runtime inspect "$BROKER_ID" --format '{{.State.Status}}')" = exited ]
echo 'Broker signal preflight passed'
