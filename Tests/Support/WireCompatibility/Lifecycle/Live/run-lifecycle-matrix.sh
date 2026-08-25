#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Live-gated lifecycle matrix. Every result is retained as a manifest: executed
# scenarios have both application and MQTT-capture evidence; unavailable
# scenarios are explicitly ``unsupported`` and are never treated as passes.
#
# A scenario is a separately-owned process group. The matrix watches that group
# with a monotonic wall-clock deadline and an output-progress deadline. This is
# deliberately kept here, at the boundary that starts a live runner, so a
# runner that wedges in a container/runtime call cannot wedge the matrix too.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)
HERE="$ROOT/Tests/Support/WireCompatibility/Lifecycle/Live"
WIRE_TOOL="$ROOT/Tests/Support/WireCompatibility/tool/dist/index.js"
OUTPUT_BASE="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}"
SCENARIOS="${WIRE_LIFECYCLE_SCENARIOS:-offline-queueing reconnect-resubscribe broker-restart graceful-deadvertise unexpected-disconnect-last-will clean-session duplicate-reply late-reply qos-0 qos-1 qos-2}"

# WIRE_LIFECYCLE_DEADLINE_SECONDS remains an alias for callers of the old
# matrix. The explicit wall/no-progress names make the two independent bounds
# clear to operators and to offline self-tests.
WALL_SECONDS="${WIRE_LIFECYCLE_WALL_SECONDS:-${WIRE_LIFECYCLE_DEADLINE_SECONDS:-600}}"
NO_PROGRESS_SECONDS="${WIRE_LIFECYCLE_NO_PROGRESS_SECONDS:-120}"
TERM_GRACE_SECONDS="${WIRE_LIFECYCLE_TERM_GRACE_SECONDS:-10}"
KILL_GRACE_SECONDS="${WIRE_LIFECYCLE_KILL_GRACE_SECONDS:-5}"
REAP_SECONDS="${WIRE_LIFECYCLE_REAP_SECONDS:-5}"
PROGRESS_INTERVAL_SECONDS="${WIRE_LIFECYCLE_PROGRESS_INTERVAL_SECONDS:-5}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
RUNTIME_API_TIMEOUT_SECONDS="${WIRE_LIFECYCLE_RUNTIME_API_TIMEOUT_SECONDS:-$REAP_SECONDS}"

command -v setsid >/dev/null 2>&1 || {
    echo "lifecycle matrix requires setsid for process-group ownership" >&2
    exit 69
}
if command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
    echo "lifecycle matrix requires timeout for bounded runtime cleanup" >&2
    exit 69
fi

monotonic_ms() {
    # /proc/uptime is backed by CLOCK_MONOTONIC on Linux. Keep a conservative
    # fallback for macOS shell self-tests, where Bash's SECONDS is monotonic
    # for the lifetime of this process.
    if [ -r /proc/uptime ]; then
        awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime
    else
        printf '%s000\n' "$SECONDS"
    fi
}

positive_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] ;;
    esac
}

for timing_value in "$WALL_SECONDS" "$NO_PROGRESS_SECONDS" "$TERM_GRACE_SECONDS" \
    "$KILL_GRACE_SECONDS" "$REAP_SECONDS" "$PROGRESS_INTERVAL_SECONDS"; do
    positive_integer "$timing_value" || {
        echo "lifecycle timing values must be positive integers" >&2
        exit 64
    }
done
positive_integer "$RUNTIME_API_TIMEOUT_SECONDS" || {
    echo "WIRE_LIFECYCLE_RUNTIME_API_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 64
}

RUN_ID="${WIRE_LIFECYCLE_RUN_ID:-${WIRE_RUN_ID:-lifecycle-$$-$(monotonic_ms)}}"
case "$RUN_ID" in
    ''|*[!A-Za-z0-9_.-]*)
        echo "WIRE_RUN_ID must contain only letters, digits, '.', '_' or '-'" >&2
        exit 64
        ;;
esac
OUTPUT_ROOT="${WIRE_LIFECYCLE_RUN_DIR:-$OUTPUT_BASE/lifecycle/$RUN_ID}"

SCENARIO_LIST=()
read -r -a SCENARIO_LIST <<< "$SCENARIOS"
for scenario in "${SCENARIO_LIST[@]}"; do
    case "$scenario" in
        offline-queueing|reconnect-resubscribe|broker-restart|graceful-deadvertise|unexpected-disconnect-last-will|clean-session|duplicate-reply|late-reply|qos-0|qos-1|qos-2) ;;
        *)
            echo "invalid lifecycle scenario id: $scenario" >&2
            exit 64
            ;;
    esac
done

mkdir -p "$OUTPUT_ROOT"

runtime_bounded() {
    if ! command -v timeout >/dev/null 2>&1; then
        echo "lifecycle runtime API requires timeout for bounded cleanup" >&2
        return 69
    fi
    timeout "$RUNTIME_API_TIMEOUT_SECONDS" "$CONTAINER_RUNTIME" "$@"
}

diagnostic() {
    local scenario="$1" phase="$2" pid="${3:--}" elapsed="${4:--}" idle="${5:--}" bytes="${6:--}"
    printf '[wire-lifecycle] run=%s scenario=%s phase=%s pid=%s elapsed=%ss idle=%ss output=%sB\n' \
        "$RUN_ID" "$scenario" "$phase" "$pid" "$elapsed" "$idle" "$bytes"
}

process_inventory() {
    local output="$1"
    {
        echo "# process inventory run=$RUN_ID captured=$(monotonic_ms)"
        ps -eo pid=,ppid=,pgid=,sid=,stat=,etime=,args= || true
    } >"$output" 2>&1
}

container_inventory() {
    local output="$1" scenario="$2"
    {
        echo "# container inventory run=$RUN_ID scenario=$scenario captured=$(monotonic_ms)"
        if ! command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1; then
            echo "runtime unavailable: $CONTAINER_RUNTIME"
            return 0
        fi
        runtime_bounded ps -a --no-trunc \
            --filter "label=io.axoloty.managed-by=axoloty-wire-lifecycle" \
            --filter "label=io.axoloty.run-id=$RUN_ID" \
            --filter "label=io.axoloty.scenario=$scenario" \
            --format 'container={{.ID}} name={{.Names}} status={{.Status}} labels={{.Labels}}' || true
        runtime_bounded network ls --no-trunc \
            --filter "label=io.axoloty.managed-by=axoloty-wire-lifecycle" \
            --filter "label=io.axoloty.run-id=$RUN_ID" \
            --filter "label=io.axoloty.scenario=$scenario" \
            --format 'network={{.ID}} name={{.Name}} labels={{.Labels}}' || true
    } >"$output" 2>&1
}

cleanup_owned_runtime() {
    local scenario="$1" artifact_dir="$2" id
    if ! command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1; then
        return 0
    fi

    # Labels are the ownership boundary. Names are human-readable only; do
    # not remove an unlabelled object merely because a run id happens to match.
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        runtime_bounded logs "$id" >"$artifact_dir/container-$id.log" 2>&1 || true
        runtime_bounded rm -f "$id" >/dev/null 2>&1 || true
    done < <(runtime_bounded ps -aq \
        --filter "label=io.axoloty.managed-by=axoloty-wire-lifecycle" \
        --filter "label=io.axoloty.run-id=$RUN_ID" \
        --filter "label=io.axoloty.scenario=$scenario" 2>/dev/null || true)

    while IFS= read -r id; do
        [ -n "$id" ] || continue
        runtime_bounded network rm "$id" >/dev/null 2>&1 || true
    done < <(runtime_bounded network ls -q \
        --filter "label=io.axoloty.managed-by=axoloty-wire-lifecycle" \
        --filter "label=io.axoloty.run-id=$RUN_ID" \
        --filter "label=io.axoloty.scenario=$scenario" 2>/dev/null || true)
}

group_id_for() {
    local pid="$1" group
    group="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$group" in
        ''|*[!0-9]*) return 1 ;;
        *) printf '%s\n' "$group" ;;
    esac
}

group_alive() {
    local group="$1"
    [ "$group" -gt 1 ] 2>/dev/null && kill -0 -- "-$group" 2>/dev/null
}

pid_live() {
    local pid="$1" state
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$state" in
        ''|Z*) return 1 ;;
        *) kill -0 "$pid" 2>/dev/null ;;
    esac
}

terminate_leader_bounded() {
    local pid="$1" deadline
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$(( $(monotonic_ms) + TERM_GRACE_SECONDS * 1000 ))
    while pid_live "$pid" && [ "$(monotonic_ms)" -lt "$deadline" ]; do
        sleep 0.2
    done
    if pid_live "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
        deadline=$(( $(monotonic_ms) + KILL_GRACE_SECONDS * 1000 ))
        while pid_live "$pid" && [ "$(monotonic_ms)" -lt "$deadline" ]; do
            sleep 0.2
        done
    fi
    if pid_live "$pid"; then
        return 1
    fi
    wait "$pid" >/dev/null 2>&1 || true
    return 0
}

reap_process_if_stopped() {
    local pid="$1" state
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$state" in
        ''|Z*)
            wait "$pid" >/dev/null 2>&1 || true
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

valid_owned_group() {
    local pid="$1" group="$2"
    case "$group" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$group" -gt 1 ] 2>/dev/null && [ "$group" -eq "$pid" ]
}

wait_for_group_exit() {
    local group="$1" grace_seconds="$2" deadline now
    deadline=$(( $(monotonic_ms) + grace_seconds * 1000 ))
    while group_alive "$group"; do
        now="$(monotonic_ms)"
        [ "$now" -lt "$deadline" ] || return 1
        sleep 0.2
    done
    return 0
}

terminate_group_bounded() {
    local scenario="$1" pid="$2" phase="$3" group="${4:-}" elapsed="${5:--}" idle="${6:--}" bytes="${7:--}"
    if [ -z "$group" ]; then
        group="$(group_id_for "$pid" || true)"
    fi
    if [ -z "$group" ]; then
        diagnostic "$scenario" "$phase-no-group" "$pid" "$elapsed" "$idle" "$bytes"
        return 0
    fi

    if group_alive "$group"; then
        diagnostic "$scenario" "$phase-term" "$pid" "$elapsed" "$idle" "$bytes"
        kill -TERM -- "-$group" 2>/dev/null || true
        if ! wait_for_group_exit "$group" "$TERM_GRACE_SECONDS"; then
            diagnostic "$scenario" "$phase-kill" "$pid" "$elapsed" "$idle" "$bytes"
            kill -KILL -- "-$group" 2>/dev/null || true
            if ! wait_for_group_exit "$group" "$KILL_GRACE_SECONDS"; then
                diagnostic "$scenario" "$phase-reap-timeout" "$pid" "$elapsed" "$idle" "$bytes"
                return 1
            fi
        fi
    fi
    diagnostic "$scenario" "$phase-reaped" "$pid" "$elapsed" "$idle" "$bytes"
    return 0
}

wait_for_stream_bounded() {
    local stream_pid="$1" deadline now
    deadline=$(( $(monotonic_ms) + REAP_SECONDS * 1000 ))
    while pid_live "$stream_pid"; do
        now="$(monotonic_ms)"
        [ "$now" -lt "$deadline" ] || break
        sleep 0.2
    done
    if pid_live "$stream_pid"; then
        kill -TERM "$stream_pid" 2>/dev/null || true
        deadline=$(( $(monotonic_ms) + KILL_GRACE_SECONDS * 1000 ))
        while pid_live "$stream_pid" && [ "$(monotonic_ms)" -lt "$deadline" ]; do
            sleep 0.2
        done
        if pid_live "$stream_pid"; then
            kill -KILL "$stream_pid" 2>/dev/null || true
            deadline=$(( $(monotonic_ms) + REAP_SECONDS * 1000 ))
            while pid_live "$stream_pid" && [ "$(monotonic_ms)" -lt "$deadline" ]; do
                sleep 0.2
            done
        fi
    fi
    if pid_live "$stream_pid"; then
        return 1
    fi
    wait "$stream_pid" >/dev/null 2>&1 || true
    return 0
}

scenario_command() {
    local scenario="$1"
    if [ -n "${WIRE_LIFECYCLE_SCENARIO_RUNNER:-}" ]; then
        SCENARIO_COMMAND=("$WIRE_LIFECYCLE_SCENARIO_RUNNER" "$scenario")
        return 0
    fi
    case "$scenario" in
        unexpected-disconnect-last-will)
            SCENARIO_COMMAND=("$HERE/run-coatyjs-last-will.sh") ;;
        qos-0|graceful-deadvertise)
            SCENARIO_COMMAND=("$HERE/run-coatyjs-qos-scenario.sh" "$scenario") ;;
        duplicate-reply|late-reply)
            SCENARIO_COMMAND=("$HERE/run-lifecycle-call-return.sh" "$scenario") ;;
        offline-queueing|reconnect-resubscribe|broker-restart|clean-session)
            SCENARIO_COMMAND=("$HERE/run-lifecycle-network.sh" "$scenario") ;;
        qos-1|qos-2)
            SCENARIO_COMMAND=() ;;
        *)
            echo "Unknown lifecycle scenario: $scenario" >&2
            return 64 ;;
    esac
}

ACTIVE_PID=""
ACTIVE_GROUP=""
ACTIVE_STREAM_PID=""
ACTIVE_FIFO=""
ACTIVE_ARTIFACT_DIR=""
ACTIVE_SCENARIO=""
STREAM_STATUS=0

cleanup_active_stream() {
    if [ -n "$ACTIVE_STREAM_PID" ]; then
        if wait_for_stream_bounded "$ACTIVE_STREAM_PID"; then
            STREAM_STATUS=0
        else
            STREAM_STATUS=$?
        fi
    fi
    ACTIVE_STREAM_PID=""
    if [ -n "$ACTIVE_FIFO" ]; then
        rm -f "$ACTIVE_FIFO"
        ACTIVE_FIFO=""
    fi
    return 0
}

handle_signal() {
    local signal="$1"
    if [ -n "$ACTIVE_PID" ]; then
        diagnostic "$ACTIVE_SCENARIO" "matrix-$signal" "$ACTIVE_PID"
        terminate_group_bounded "$ACTIVE_SCENARIO" "$ACTIVE_PID" "signal-$signal" "$ACTIVE_GROUP" || true
    fi
    exit 143
}

trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

finalize_exit() {
    cleanup_active_stream
    if [ -n "$ACTIVE_ARTIFACT_DIR" ]; then
        cleanup_owned_runtime "$ACTIVE_SCENARIO" "$ACTIVE_ARTIFACT_DIR"
        process_inventory "$ACTIVE_ARTIFACT_DIR/process-inventory.exit.txt"
        container_inventory "$ACTIVE_ARTIFACT_DIR/container-inventory.exit.txt" "$ACTIVE_SCENARIO"
    fi
}

trap finalize_exit EXIT

run_scenario() {
    local scenario="$1" artifact_dir="$2" verifier_log="$3" fifo
    local start_ms now elapsed idle bytes last_bytes last_progress report_at
    local timed_out=0 timeout_phase="" scenario_status=0
    local scenario_pid group group_probe_deadline

    : >"$verifier_log"
    scenario_command "$scenario" || return $?
    if [ "${#SCENARIO_COMMAND[@]}" -eq 0 ]; then
        diagnostic "$scenario" unsupported - 0 0 0
        process_inventory "$artifact_dir/process-inventory.after.txt"
        container_inventory "$artifact_dir/container-inventory.after.txt" "$scenario"
        return 0
    fi
    fifo="$artifact_dir/runner-output.pipe"
    rm -f "$fifo"
    mkfifo "$fifo"
    ACTIVE_FIFO="$fifo"
    ACTIVE_ARTIFACT_DIR="$artifact_dir"
    ACTIVE_SCENARIO="$scenario"
    STREAM_STATUS=0

    # tee retains a lossless verifier log while keeping runner diagnostics
    # visible to the operator. It is outside the scenario group and is reaped
    # explicitly below.
    tee -a "$verifier_log" <"$fifo" &
    ACTIVE_STREAM_PID=$!
    setsid env "WIRE_OUTPUT_DIR=$artifact_dir" "WIRE_RUN_ID=$RUN_ID" \
        "WIRE_RUNTIME_MANAGED_BY=axoloty-wire-lifecycle" \
        "WIRE_RUNTIME_RUN_ID=$RUN_ID" "WIRE_RUNTIME_SCENARIO=$scenario" \
        "${SCENARIO_COMMAND[@]}" >"$fifo" 2>&1 &
    scenario_pid=$!
    ACTIVE_PID="$scenario_pid"
    group="$(group_id_for "$scenario_pid" || true)"
    # setsid may need a scheduling turn to replace itself with the runner. Do
    # not mistake that short hand-off window for an ownership violation.
    group_probe_deadline=$(( $(monotonic_ms) + 1000 ))
    while ! valid_owned_group "$scenario_pid" "$group" && \
        kill -0 "$scenario_pid" 2>/dev/null && \
        [ "$(monotonic_ms)" -lt "$group_probe_deadline" ]; do
        sleep 0.01
        group="$(group_id_for "$scenario_pid" || true)"
    done
    if [ -n "${WIRE_LIFECYCLE_TEST_FORCE_PGID:-}" ]; then
        group="$WIRE_LIFECYCLE_TEST_FORCE_PGID"
    fi
    ACTIVE_GROUP="$group"
    printf 'pid=%s pgid=%s\n' "$scenario_pid" "${group:--}" >"$artifact_dir/process-group.txt"
    if ! valid_owned_group "$scenario_pid" "$group"; then
        diagnostic "$scenario" ownership-failed "$scenario_pid" 0 0 0 >>"$verifier_log"
        diagnostic "$scenario" ownership-failed "$scenario_pid" 0 0 0
        terminate_leader_bounded "$scenario_pid"
        scenario_status=125
        cleanup_active_stream
        process_inventory "$artifact_dir/process-inventory.after.txt"
        container_inventory "$artifact_dir/container-inventory.after.txt" "$scenario"
        ACTIVE_PID=""
        ACTIVE_GROUP=""
        ACTIVE_ARTIFACT_DIR=""
        ACTIVE_SCENARIO=""
        ACTIVE_FIFO=""
        return "$scenario_status"
    fi
    start_ms="$(monotonic_ms)"
    last_bytes=0
    last_progress="$start_ms"
    report_at="$start_ms"
    elapsed=0
    idle=0
    bytes=0
    diagnostic "$scenario" launch "$scenario_pid" 0 0 0

    while kill -0 "$scenario_pid" 2>/dev/null; do
        now="$(monotonic_ms)"
        elapsed=$(( (now - start_ms) / 1000 ))
        bytes="$(wc -c <"$verifier_log" 2>/dev/null || printf '0')"
        if [ "$bytes" -gt "$last_bytes" ]; then
            last_bytes="$bytes"
            last_progress="$now"
        fi
        idle=$(( (now - last_progress) / 1000 ))
        if [ "$now" -ge "$report_at" ]; then
            diagnostic "$scenario" running "$scenario_pid" "$elapsed" "$idle" "$bytes"
            report_at=$(( now + PROGRESS_INTERVAL_SECONDS * 1000 ))
        fi
        if [ "$elapsed" -ge "$WALL_SECONDS" ]; then
            timed_out=1
            timeout_phase=wall-timeout
            break
        fi
        if [ "$idle" -ge "$NO_PROGRESS_SECONDS" ]; then
            timed_out=1
            timeout_phase=no-progress-timeout
            break
        fi
        sleep 0.2
    done

    if [ "$timed_out" -eq 1 ]; then
        now="$(monotonic_ms)"
        elapsed=$(( (now - start_ms) / 1000 ))
        bytes="$(wc -c <"$verifier_log" 2>/dev/null || printf '0')"
        idle=$(( (now - last_progress) / 1000 ))
        diagnostic "$scenario" "$timeout_phase" "$scenario_pid" "$elapsed" "$idle" "$bytes"
        if terminate_group_bounded "$scenario" "$scenario_pid" timeout "$group" "$elapsed" "$idle" "$bytes"; then
            scenario_status=124
        else
            scenario_status=125
        fi
    fi

    if reap_process_if_stopped "$scenario_pid"; then
        child_status=0
    else
        child_status=125
    fi
    if [ "$timed_out" -eq 0 ]; then
        scenario_status="$child_status"
        # A runner can exit while a helper keeps its process group alive. Own
        # and reap that group before accepting the runner's exit status.
        if group_alive "$group"; then
            terminate_group_bounded "$scenario" "$scenario_pid" descendant "$group" || scenario_status=125
        fi
    fi
    cleanup_active_stream
    if [ "$STREAM_STATUS" -ne 0 ]; then
        diagnostic "$scenario" tee-failed "$scenario_pid" "$elapsed" "$idle" "$bytes" >>"$verifier_log"
        diagnostic "$scenario" tee-failed "$scenario_pid" "$elapsed" "$idle" "$bytes"
        scenario_status=125
    fi
    process_inventory "$artifact_dir/process-inventory.after.txt"
    container_inventory "$artifact_dir/container-inventory.after.txt" "$scenario"
    ACTIVE_PID=""
    ACTIVE_GROUP=""
    ACTIVE_ARTIFACT_DIR=""
    ACTIVE_SCENARIO=""
    ACTIVE_FIFO=""
    return "$scenario_status"
}

write_manifest() {
    local scenario="$1" artifact_dir="$2" manifest="$3" verifier_log="$4"
    if [ "$scenario" = "unexpected-disconnect-last-will" ]; then
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
            --application-log "$artifact_dir/coatyjs-last-will.application.jsonl" \
            --capture "$artifact_dir/coatyjs-last-will.jsonl" 2>&1 | tee -a "$verifier_log"
    elif [ "$scenario" = "qos-0" ] || [ "$scenario" = "graceful-deadvertise" ]; then
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
            --application-log "$artifact_dir/coatyjs-$scenario.application.jsonl" \
            --capture "$artifact_dir/coatyjs-$scenario.jsonl" 2>&1 | tee -a "$verifier_log"
    elif [ "$scenario" = "duplicate-reply" ] || [ "$scenario" = "late-reply" ]; then
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
            --application-log "$artifact_dir/axoloty-$scenario.application.jsonl" \
            --capture "$artifact_dir/axoloty-$scenario.jsonl" 2>&1 | tee -a "$verifier_log"
    elif [ "$scenario" = "offline-queueing" ] || [ "$scenario" = "reconnect-resubscribe" ] \
        || [ "$scenario" = "broker-restart" ] || [ "$scenario" = "clean-session" ]; then
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
            --application-log "$artifact_dir/axoloty-$scenario.application.jsonl" \
            --capture "$artifact_dir/axoloty-$scenario.jsonl" 2>&1 | tee -a "$verifier_log"
    else
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" 2>&1 | tee -a "$verifier_log"
    fi
    local -a pipeline_status=("${PIPESTATUS[@]}")
    if [ "${pipeline_status[1]:-1}" -ne 0 ]; then
        printf '[wire-lifecycle] scenario=%s phase=manifest-tee-failed\n' "$scenario" >>"$verifier_log"
        printf '[wire-lifecycle] scenario=%s phase=manifest-tee-failed\n' "$scenario" >&2
        return 125
    fi
    return "${pipeline_status[0]:-125}"
}

for scenario in "${SCENARIO_LIST[@]}"; do
    artifact_dir="$OUTPUT_ROOT/$scenario"
    mkdir -p "$artifact_dir"
    verifier_log="$artifact_dir/verifier.log"
    manifest="$artifact_dir/manifest.json"
    rm -f "$manifest"
    process_inventory "$artifact_dir/process-inventory.before.txt"
    container_inventory "$artifact_dir/container-inventory.before.txt" "$scenario"
    diagnostic "$scenario" prepare - 0 0 0

    set +e
    run_scenario "$scenario" "$artifact_dir" "$verifier_log"
    scenario_status=$?
    set -e
    cleanup_owned_runtime "$scenario" "$artifact_dir"
    process_inventory "$artifact_dir/process-inventory.final.txt"
    container_inventory "$artifact_dir/container-inventory.final.txt" "$scenario"
    if [ "$scenario_status" -ne 0 ]; then
        echo "Lifecycle scenario failed (status=$scenario_status): $scenario" >&2
        exit "$scenario_status"
    fi

    diagnostic "$scenario" verify - 0 0 "$(wc -c <"$verifier_log" 2>/dev/null || printf '0')"
    set +e
    write_manifest "$scenario" "$artifact_dir" "$manifest" "$verifier_log"
    manifest_status=$?
    set -e
    if [ "$manifest_status" -ne 0 ]; then
        echo "Lifecycle manifest failed: $scenario" >&2
        exit "$manifest_status"
    fi
    echo "Lifecycle manifest retained at $manifest"
done
