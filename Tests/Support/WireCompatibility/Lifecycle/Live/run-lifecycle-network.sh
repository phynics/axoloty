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
runtime_bounded() { timeout "${WIRE_CONTAINER_WAIT_SECONDS:-120}s" "$RUNTIME" "$@"; }
create_runtime_id() {
    local variable="$1" created_id
    shift
    if created_id="$(runtime "$@")"; then
        printf -v "$variable" '%s' "$created_id"
    else
        return $?
    fi
}
wait_for_container_exit() {
    local container_id="$1" wait_seconds="${2:-${WIRE_CONTAINER_WAIT_SECONDS:-120}}"
    local deadline=$(( $(date +%s) + wait_seconds )) state
    while :; do
        if ! state="$(runtime_bounded inspect "$container_id" --format '{{.State.Status}}')"; then
            echo "Failed to inspect owned lifecycle container $container_id while waiting for it to stop" >&2
            return 1
        fi
        case "$state" in
            exited|stopped) return 0 ;;
            running|stopping) ;;
            *) echo "Owned lifecycle container $container_id entered unexpected state $state while stopping" >&2; return 1 ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            return 2
        fi
        sleep 0.2
    done
}
finish_container_stop() {
    local container_id="$1" wait_status state
    if wait_for_container_exit "$container_id" "${WIRE_CONTAINER_TERM_GRACE_SECONDS:-2}"; then
        return 0
    else
        wait_status=$?
        if [ "$wait_status" -ne 2 ]; then return "$wait_status"; fi
    fi
    echo "Owned lifecycle container $container_id did not exit after SIGTERM; escalating to SIGKILL" >&2
    if runtime_bounded kill --signal KILL "$container_id"; then
        :
    else
        wait_status=$?
        if ! state="$(runtime_bounded inspect "$container_id" --format '{{.State.Status}}')"; then
            echo "Failed to inspect owned lifecycle container $container_id after SIGKILL failed" >&2
            return "$wait_status"
        fi
        case "$state" in
            exited|stopped) ;;
            *) echo "Failed to SIGKILL owned lifecycle container $container_id (state=$state)" >&2; return "$wait_status" ;;
        esac
    fi
    if ! wait_for_container_exit "$container_id"; then
        echo "Timed out waiting for SIGKILL to stop owned lifecycle container $container_id" >&2
        return 1
    fi
}
remove_owned_container() {
    local container_id="$1" state
    if ! state="$(runtime_bounded inspect "$container_id" --format '{{.State.Status}}')"; then
        echo "Failed to inspect owned lifecycle container $container_id before removal" >&2
        return 1
    fi
    if [ "$state" = "running" ]; then
        # Separate signaling from removal to avoid remote `rm -f` getting stuck
        # in Stopping. Signal the broker as its service user: root inside the
        # container can lack CAP_KILL, and host runtime signaling can fail when
        # the broker runs under a different UID. Other containers use the runtime.
        local -a signal_command=(kill --signal TERM "$container_id")
        if [ "$container_id" = "$BROKER_ID" ]; then
            signal_command=(exec --user mosquitto "$container_id" kill -TERM 1)
        fi
        if runtime_bounded "${signal_command[@]}"; then
            :
        else
            local signal_status=$?
            echo "Failed to signal owned lifecycle container $container_id" >&2
            return "$signal_status"
        fi
        if ! finish_container_stop "$container_id"; then return 1; fi
        if ! state="$(runtime_bounded inspect "$container_id" --format '{{.State.Status}}')"; then
            echo "Failed to inspect owned lifecycle container $container_id after it stopped" >&2
            return 1
        fi
    elif [ "$state" = "stopping" ]; then
        if ! finish_container_stop "$container_id"; then return 1; fi
        if ! state="$(runtime_bounded inspect "$container_id" --format '{{.State.Status}}')"; then
            echo "Failed to inspect owned lifecycle container $container_id after it stopped" >&2
            return 1
        fi
    fi
    case "$state" in
        exited|stopped|created) ;;
        *) echo "Owned lifecycle container $container_id did not stop (state=$state)" >&2; return 1 ;;
    esac
    if ! runtime rm "$container_id" >/dev/null; then
        echo "Failed to remove stopped owned lifecycle container $container_id" >&2
        return 1
    fi
}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
LIVE="$ROOT/Tests/Support/WireCompatibility/Live"
TOOL=/tool/dist/index.js
OUT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
# CI invokes this runner with repository-relative artifact paths. Resolve that
# boundary before deriving paths that are mounted into the subject container.
case "$OUT" in
    /*) ;;
    *) OUT="$ROOT/$OUT" ;;
esac
RUN_ID="${WIRE_RUN_ID:-$$}"
NETWORK="axoloty-lifecycle-$SCENARIO-$RUN_ID"
BROKER="axoloty-lifecycle-broker-$SCENARIO-$RUN_ID"
PROBE="axoloty-lifecycle-probe-$SCENARIO-$RUN_ID"
PROXY="axoloty-lifecycle-proxy-$SCENARIO-$RUN_ID"
SUBJECT="axoloty-lifecycle-subject-$SCENARIO-$RUN_ID"
# Container names include scenario and run identity for cleanup ownership. Use
# short aliases for network clients because container names are also DNS names
# and can exceed the 63-character DNS label limit on longer scenarios.
BROKER_HOST="broker"
PROXY_HOST="proxy"
DEV_IMAGE="${DEV_IMAGE:-localhost/axoloty-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT/.swiftpm-cache}"
BUILD_DIR="${BUILD_DIR:-/tmp/coaty-swift-build/.git/swift-6.4-linux/debug}"
SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/axoloty-wire-module-cache}"
NAMESPACE="wire-lifecycle-$SCENARIO-$RUN_ID"
CAPTURE="$OUT/axoloty-$SCENARIO.jsonl"
CAPTURE_READY="$OUT/axoloty-$SCENARIO.capture-ready"
APPLICATION_LOG="$OUT/axoloty-$SCENARIO.application.jsonl"
RAW_LOG="$OUT/axoloty-$SCENARIO.subject.log"
CONNACK_LOG="$OUT/axoloty-$SCENARIO.connack.jsonl"
PROXY_READY="$OUT/axoloty-$SCENARIO.proxy-ready"
RECONNECT_READY="$OUT/axoloty-$SCENARIO.reconnect-ready"
BROKER_RESTART_IDS="$OUT/axoloty-$SCENARIO.broker-restart-ids.txt"
NETWORK_ID=""
BROKER_ID=""
PROBE_ID=""
PROXY_ID=""
SUBJECT_ID=""
RUNTIME_LABELS=(
    --label "io.axoloty.managed-by=${WIRE_RUNTIME_MANAGED_BY:-axoloty-wire-lifecycle}"
    --label "io.axoloty.run-id=${WIRE_RUNTIME_RUN_ID:-$RUN_ID}"
    --label "io.axoloty.scenario=${WIRE_RUNTIME_SCENARIO:-$SCENARIO}"
)
case "$RECONNECT_READY" in
    "$ROOT"/*) RECONNECT_READY_REL="${RECONNECT_READY#"$ROOT/"}" ;;
    *) echo "WIRE_OUTPUT_DIR must be inside the repository so the subject can observe reconnect readiness" >&2; exit 64 ;;
esac

cleanup() {
    local result=$? cleanup_failed=0 container_id
    trap - EXIT INT TERM
    for container_id in \
        "$SUBJECT_ID|subject-container" \
        "$PROXY_ID|proxy-container" \
        "$PROBE_ID|probe-container" \
        "$BROKER_ID|broker-container"; do
        [ -n "${container_id%%|*}" ] || continue
        local id="${container_id%%|*}" log_name="${container_id#*|}"
        if ! runtime logs "$id" >"$OUT/$log_name-$SCENARIO.log" 2>&1; then
            echo "Failed to capture logs for owned lifecycle container $id" >&2
        fi
        if ! remove_owned_container "$id"; then
            echo "Failed to remove owned lifecycle container $id" >&2
            cleanup_failed=1
        fi
    done
    if [ -n "$NETWORK_ID" ] && ! runtime network rm "$NETWORK_ID" >/dev/null; then
        echo "Failed to remove owned lifecycle network $NETWORK_ID" >&2
        cleanup_failed=1
    fi
    if [ "$result" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then
        result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$OUT"
rm -f "$CAPTURE" "$CAPTURE.post-restart" "$CAPTURE_READY" "$APPLICATION_LOG" "$RAW_LOG" "$CONNACK_LOG" "$PROXY_READY" "$RECONNECT_READY" "$BROKER_RESTART_IDS"

create_runtime_id NETWORK_ID network create "$NETWORK" "${RUNTIME_LABELS[@]}"
start_broker() {
    create_runtime_id BROKER_ID run -d --name "$BROKER" --user mosquitto --network "$NETWORK_ID" --network-alias "$BROKER_HOST" "${RUNTIME_LABELS[@]}" \
        -v "$LIVE/mosquitto.conf:/etc/mosquitto/wire-compat.conf:ro" \
        "$DEV_IMAGE" mosquitto -c /etc/mosquitto/wire-compat.conf
}
wait_for() {
    local description="$1" condition="$2" limit=$(( $(date +%s) + ${WIRE_LIFECYCLE_DEADLINE_SECONDS:-600} ))
    while ! eval "$condition"; do
        if [ "$(date +%s)" -ge "$limit" ]; then echo "Timed out waiting for $description" >&2; return 1; fi
        sleep 0.2
    done
}
broker_ready() { runtime exec "$BROKER_ID" node -e 'const s=require("node:net").createConnection({host:"127.0.0.1",port:1883},()=>s.end()); s.on("error",()=>process.exit(1))' >/dev/null 2>&1; }
start_broker
wait_for "Mosquitto broker readiness" broker_ready

start_capture() {
    local output="$1"
    rm -f "$CAPTURE_READY"
    create_runtime_id PROBE_ID run -d --name "$PROBE" --network "$NETWORK_ID" -v "$ROOT/Tests/Support/WireCompatibility/tool:/tool:ro,Z" -v "$OUT:/artifacts" \
        --entrypoint node --user 0 "${RUNTIME_LABELS[@]}" "$JS_IMAGE" "$TOOL" capture '#' "/artifacts/${output##*/}" \
        --host "$BROKER_HOST" --producer coatyswift-modern --producer-version current --scenario "$SCENARIO" \
        --ready-file "/artifacts/${CAPTURE_READY##*/}"
    local limit=$(( $(date +%s) + ${WIRE_LIFECYCLE_DEADLINE_SECONDS:-600} )) state
    while [ ! -f "$CAPTURE_READY" ]; do
        state="$(runtime_bounded inspect "$PROBE_ID" --format '{{.State.Status}}')"
        if [ "$state" != "running" ]; then
            runtime logs "$PROBE_ID" >&2 || true
            echo "Capture process exited with status $state before subscription readiness" >&2
            return 1
        fi
        if [ "$(date +%s)" -ge "$limit" ]; then
            echo "Timed out waiting for capture subscription" >&2
            return 1
        fi
        sleep 0.2
    done
}
start_capture "$CAPTURE"

SUBJECT_HOST="$BROKER_HOST"
if [ "$SCENARIO" != "broker-restart" ]; then
    create_runtime_id PROXY_ID run -d --name "$PROXY" --network "$NETWORK_ID" --network-alias "$PROXY_HOST" -v "$ROOT/Tests/Support/WireCompatibility/tool:/tool:ro,Z" -v "$OUT:/artifacts" \
        --entrypoint node --user 0 "${RUNTIME_LABELS[@]}" "$JS_IMAGE" "$TOOL" proxy --listen-port 1883 --broker-host "$BROKER_HOST" --broker-port 1883 \
        --control-port 18884 --connack-log "/artifacts/${CONNACK_LOG##*/}" --ready-file "/artifacts/${PROXY_READY##*/}"
    wait_for "TCP proxy readiness" "test -f '$PROXY_READY'"
    SUBJECT_HOST="$PROXY_HOST"
fi

test_name="$(case "$SCENARIO" in offline-queueing) echo offlineQueueing ;; reconnect-resubscribe) echo reconnectResubscribe ;; broker-restart) echo brokerRestart ;; clean-session) echo cleanSession ;; esac)"
env_flag="WIRE_LIFECYCLE_$(echo "$SCENARIO" | tr 'a-z-' 'A-Z_')_LIVE"
create_runtime_id SUBJECT_ID run -d -t --name "$SUBJECT" --network "$NETWORK_ID" -v "$ROOT:/workspace" -v "$SPM_CACHE_DIR:/swiftpm-cache" -v "$BUILD_DIR:/swift-build" -w /workspace \
    "${RUNTIME_LABELS[@]}" \
    -e "$env_flag=1" -e WIRE_BROKER_HOST="$SUBJECT_HOST" -e WIRE_BROKER_PORT=1883 -e WIRE_NAMESPACE="$NAMESPACE" \
    -e WIRE_RECONNECT_READY="/workspace/$RECONNECT_READY_REL" \
    -e "SWIFTPM_MODULECACHE_OVERRIDE=$SWIFTPM_MODULECACHE_OVERRIDE" \
    "$DEV_IMAGE" swift test -Xswiftc -module-cache-path -Xswiftc "$SWIFTPM_MODULECACHE_OVERRIDE" \
    --skip-build --scratch-path /swift-build --cache-path /swiftpm-cache --disable-automatic-resolution --filter "AxolotyLifecycleSubjectTests/$test_name"
subject_reported() { runtime logs "$SUBJECT_ID" 2>&1 >"$RAW_LOG"; grep -q "\"state\":\"$1\"" "$RAW_LOG"; }
wait_for "subject readiness" "subject_reported ready"

publish_probe() {
    runtime run --rm --network "$NETWORK_ID" "${RUNTIME_LABELS[@]}" --entrypoint node \
        -v "$LIVE/coatyjs-advertise-runner.js:/agent/coatyjs-advertise-runner.js:ro" \
        -e BROKER_URL="mqtt://$BROKER_HOST:1883" -e COATY_NAMESPACE="$NAMESPACE" "$JS_IMAGE" /agent/coatyjs-advertise-runner.js
}
proxy_control() {
    runtime run --rm --network "$NETWORK_ID" "${RUNTIME_LABELS[@]}" -v "$ROOT/Tests/Support/WireCompatibility/tool:/tool:ro,Z" --entrypoint node "$JS_IMAGE" "$TOOL" proxy-control --host "$PROXY_HOST" --port 18884 --command "$1"
}
if [ "$SCENARIO" = "broker-restart" ]; then
    # These stops create the network failure under test. Continuing after a
    # failed stop would make the later reconnect wait meaningless.
    remove_owned_container "$PROBE_ID"
    PROBE_ID=""
    old_broker_id="$BROKER_ID"
    remove_owned_container "$BROKER_ID"
    BROKER_ID=""
    wait_for "subject offline transition" "subject_reported offline"
    start_broker
    wait_for "Mosquitto restart" broker_ready
    printf 'stopped=%s\nrestarted=%s\n' "$old_broker_id" "$BROKER_ID" >"$BROKER_RESTART_IDS"
    touch "$RECONNECT_READY"
    wait_for "subject reconnect" "subject_reported reconnected"
    start_capture "$CAPTURE.post-restart"
    publish_probe
else
    proxy_control sever
    wait_for "subject offline transition" "subject_reported offline"
    proxy_control restore
    touch "$RECONNECT_READY"
    wait_for "subject reconnect" "subject_reported reconnected"
    if [ "$SCENARIO" != "offline-queueing" ]; then publish_probe; fi
fi

runtime_bounded wait "$SUBJECT_ID" >/dev/null
runtime logs "$SUBJECT_ID" 2>&1 >"$RAW_LOG"
grep -E '^\{"state":' "$RAW_LOG" >"$APPLICATION_LOG" || true
remove_owned_container "$PROBE_ID"
PROBE_ID=""
if [ -f "$CAPTURE.post-restart" ]; then cat "$CAPTURE.post-restart" >>"$CAPTURE"; rm -f "$CAPTURE.post-restart"; fi
test -s "$CAPTURE" || { echo "Capture is missing or empty: $CAPTURE" >&2; exit 1; }
test -s "$APPLICATION_LOG" || { echo "Application log is missing or empty: $APPLICATION_LOG" >&2; exit 1; }
echo "Application log retained at $APPLICATION_LOG"
echo "Capture retained at $CAPTURE"
