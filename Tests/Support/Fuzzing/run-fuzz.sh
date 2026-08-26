#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ITERATIONS=${AXOLOTY_FUZZ_ITERATIONS:-250}
SEEDS=${AXOLOTY_FUZZ_SEEDS:-${AXOLOTY_FUZZ_SEED:-0x41584f4c4f5459}}
REPETITIONS=${AXOLOTY_FUZZ_REPETITIONS:-1}
JOBS=${AXOLOTY_FUZZ_JOBS:-2}
BUILD_TIMEOUT=${AXOLOTY_FUZZ_BUILD_TIMEOUT_SECONDS:-900}
CASE_TIMEOUT=${AXOLOTY_FUZZ_CASE_TIMEOUT_SECONDS:-300}
TERM_GRACE=${AXOLOTY_FUZZ_TERM_GRACE_SECONDS:-5}
KILL_GRACE=${AXOLOTY_FUZZ_KILL_GRACE_SECONDS:-2}
PROGRESS_INTERVAL=${AXOLOTY_FUZZ_PROGRESS_INTERVAL_SECONDS:-30}
OUTPUT_BASE=${AXOLOTY_FUZZ_OUTPUT_DIR:-"$ROOT_DIR/.testing/fuzz"}
RUNTIME=${CONTAINER_RUNTIME:-}
IMAGE=${IMAGE:-axoloty-dev}
SPM_CACHE_DIR=${SPM_CACHE_DIR:-}
FUZZ_BUILD_ROOT=${AXOLOTY_FUZZ_BUILD_DIR:-${BUILD_DIR:-}}
MODE=auto
FAIL_FAST=0
QUIET=0
manifest_finalized=0
interrupted=0
fuzz_build_root_temporary=0
spm_cache_temporary=0

declare -a worker_pids=()
active_process_dir=""

usage() {
    cat <<'EOF'
Usage: Tests/Support/Fuzzing/run-fuzz.sh [options]

Run deterministic Swift Testing fuzz cases and retain an auditable campaign record.

Options:
  --iterations N       Fuzz iterations per case (default: 250)
  --seeds LIST         Comma-separated decimal or hexadecimal seeds
  --repetitions N      Runs per seed (default: 1)
  --jobs N             Parallel workers with isolated build artifacts (default: 2)
  --build-timeout N    Maximum seconds allowed for each worker build (default: 900)
  --case-timeout N     Maximum seconds allowed for each fuzz case (default: 300)
  --term-grace N       Seconds to wait after SIGTERM (default: 5)
  --kill-grace N       Seconds to wait after SIGKILL (default: 2)
  --output DIR         Parent directory for timestamped campaign artifacts
  --runtime RUNTIME    podman or docker when running outside a container
  --image IMAGE        Development image (default: axoloty-dev)
  --container          Force container execution
  --direct             Force direct Swift execution inside a container
  --fail-fast          Stop after the first failing case
  --quiet              Suppress progress output (logs are still written)
  -h, --help           Show this help
EOF
}

die() {
    echo "run-fuzz.sh: $*" >&2
    exit 2
}

is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

while (($# > 0)); do
    case "$1" in
        --iterations|--seeds|--repetitions|--jobs|--build-timeout|--case-timeout|--term-grace|--kill-grace|--output|--runtime|--image)
            (($# >= 2)) || die "$1 requires a value"
            case "$1" in
                --iterations) ITERATIONS=$2 ;;
                --seeds) SEEDS=$2 ;;
                --repetitions) REPETITIONS=$2 ;;
                --jobs) JOBS=$2 ;;
                --build-timeout) BUILD_TIMEOUT=$2 ;;
                --case-timeout) CASE_TIMEOUT=$2 ;;
                --term-grace) TERM_GRACE=$2 ;;
                --kill-grace) KILL_GRACE=$2 ;;
                --output) OUTPUT_BASE=$2 ;;
                --runtime) RUNTIME=$2 ;;
                --image) IMAGE=$2 ;;
            esac
            shift 2
            ;;
        --container) MODE=container; shift ;;
        --direct) MODE=direct; shift ;;
        --fail-fast) FAIL_FAST=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

is_positive_integer "$ITERATIONS" || die "iterations must be a positive integer"
is_positive_integer "$REPETITIONS" || die "repetitions must be a positive integer"
is_positive_integer "$JOBS" || die "jobs must be a positive integer"
is_positive_integer "$BUILD_TIMEOUT" || die "build-timeout must be a positive integer"
is_positive_integer "$CASE_TIMEOUT" || die "case-timeout must be a positive integer"
is_positive_integer "$TERM_GRACE" || die "term grace must be a positive integer"
is_positive_integer "$KILL_GRACE" || die "kill grace must be a positive integer"
is_positive_integer "$PROGRESS_INTERVAL" || die "progress interval must be a positive integer"
[[ -n "$SEEDS" ]] || die "seeds must not be empty"
command -v setsid >/dev/null 2>&1 || die "setsid is required for process-group ownership"

if [[ "$MODE" == auto ]]; then
    if [[ -f /.dockerenv || -f /run/.containerenv ]]; then MODE=direct; else MODE=container; fi
fi
if [[ "$MODE" == container ]]; then
    if [[ -z "$RUNTIME" ]]; then
        if command -v podman >/dev/null 2>&1; then RUNTIME=podman
        elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
        else die "no podman or docker runtime found"; fi
    fi
    command -v "$RUNTIME" >/dev/null 2>&1 || die "container runtime not found: $RUNTIME"
fi

IFS=',' read -r -a SEED_LIST <<< "$SEEDS"
for seed in "${SEED_LIST[@]}"; do
    [[ "$seed" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || die "invalid seed: $seed"
done

timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
campaign_dir="$OUTPUT_BASE/fuzz-$timestamp-$$"
mkdir -p "$campaign_dir/logs" || die "cannot create $campaign_dir"
manifest="$campaign_dir/manifest.json"
summary="$campaign_dir/summary.tsv"
campaign_log="$campaign_dir/campaign.log"
active_process_dir="$campaign_dir/active-processes"
mkdir -p "$active_process_dir" || die "cannot create $active_process_dir"
start_epoch=$(date +%s)
git_revision=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
git_status=$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r/\\r/g;s/\t/\\t/g'
}

finalize_manifest() {
    local status_text="${1:-failed}"
    local finished_at duration case_json case_count passed_cases failed_cases
    [[ -f "$manifest" ]] || return 0
    (( manifest_finalized )) && return 0
    manifest_finalized=1

    if [[ -d "$campaign_dir/results" ]]; then
        find "$campaign_dir/results" -name '*.tsv' -type f -print0 | xargs -0r cat | sort >> "$summary"
    fi

    if [[ -f "$summary" ]]; then
        case_json=$(awk -F '\t' 'NR > 1 {
            if (n++) separator = ",";
            printf "%s{\"case\":\"%s\",\"seed\":\"%s\",\"repetition\":%s,\"iterations\":%s,\"durationSeconds\":%s,\"exitStatus\":%s,\"log\":\"%s\"}", separator, $1, $2, $3, $4, $5, $6, $7
        }' "$summary")
        case_count=$(awk 'NR > 1 { count++ } END { print count + 0 }' "$summary")
        passed_cases=$(awk -F '\t' 'NR > 1 && $6 == 0 { count++ } END { print count + 0 }' "$summary")
        failed_cases=$(awk -F '\t' 'NR > 1 && $6 != 0 { count++ } END { print count + 0 }' "$summary")
    else
        case_json=""
        case_count=0
        passed_cases=0
        failed_cases=0
    fi

    finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    duration=$(($(date +%s) - start_epoch))
    sed -i "/  \"cases\": \[\]/c\\  \"status\": \"$status_text\",\n  \"finishedAt\": \"$finished_at\",\n  \"durationSeconds\": $duration,\n  \"caseCount\": $case_count,\n  \"passedCases\": $passed_cases,\n  \"failedCases\": $failed_cases,\n  \"cases\": [$case_json]" "$manifest"
    echo "Fuzz campaign finalized with status $status_text at $finished_at" >> "$campaign_log"
}

process_is_live() {
    local pid="$1" state
    kill -0 "$pid" 2>/dev/null || return 1
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    [[ -n "$state" && "$state" != Z* ]]
}

process_group_is_live() {
    local pgid="$1"
    ps -o pid=,pgid=,stat= -g "$pgid" 2>/dev/null \
        | awk -v expected="$pgid" '$1 != "" && $2 == expected && $3 !~ /^Z/ { found = 1 } END { exit found ? 0 : 1 }'
}

owned_process_is_live() {
    process_is_live "$1" || process_group_is_live "$1"
}

wait_for_owned_process() {
    local pid="$1" grace="$2"
    local deadline=$((SECONDS + grace))
    while owned_process_is_live "$pid"; do
        (( SECONDS >= deadline )) && return 1
        sleep 0.1
    done
    return 0
}

terminate_leader_bounded() {
    local pid="$1" label="$2"
    local deadline
    if ! process_is_live "$pid"; then
        wait "$pid" 2>/dev/null || true
        return 0
    fi
    echo "[$label] sending SIGTERM to leader pid=$pid without group signalling" >&2
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + TERM_GRACE))
    while process_is_live "$pid"; do
        (( SECONDS >= deadline )) && break
        sleep 0.1
    done
    if process_is_live "$pid"; then
        echo "[$label] leader SIGTERM grace expired; sending SIGKILL to pid=$pid" >&2
        kill -KILL "$pid" 2>/dev/null || true
        deadline=$((SECONDS + KILL_GRACE))
        while process_is_live "$pid"; do
            (( SECONDS >= deadline )) && break
            sleep 0.1
        done
    fi
    if process_is_live "$pid"; then
        echo "[$label] leader cleanup failed: pid=$pid remained alive after SIGKILL" >&2
        return 1
    fi
    wait "$pid" 2>/dev/null || true
    return 0
}

terminate_owned_process() {
    local pid="$1" label="$2" current_pgid
    if ! owned_process_is_live "$pid"; then
        wait "$pid" 2>/dev/null || true
        return 0
    fi
    if process_is_live "$pid"; then
        current_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        if [[ "$current_pgid" != "$pid" ]]; then
            echo "[$label] cleanup refused: leader pid=$pid is not the owned process-group leader (pgid=${current_pgid:-unknown})" >&2
            return 1
        fi
    elif ! process_group_is_live "$pid"; then
        echo "[$label] cleanup refused: process group ownership could not be proven for pid=$pid" >&2
        return 1
    fi
    echo "[$label] sending SIGTERM to process group pid=$pid" >&2
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    if ! wait_for_owned_process "$pid" "$TERM_GRACE"; then
        echo "[$label] SIGTERM grace expired; sending SIGKILL to process group pid=$pid" >&2
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        if ! wait_for_owned_process "$pid" "$KILL_GRACE"; then
            echo "[$label] cleanup failed: process group pid=$pid remained alive after SIGKILL" >&2
            return 1
        fi
    fi
    wait "$pid" 2>/dev/null || true
    return 0
}

terminate_active_processes() {
    local marker pid
    [[ -d "$active_process_dir" ]] || return 0
    for marker in "$active_process_dir"/*; do
        [[ -f "$marker" ]] || continue
        pid=${marker##*/}
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        terminate_owned_process "$pid" "interrupt" || true
    done
}

trap_signal() {
    interrupted=1
    terminate_active_processes
    if (( ${#worker_pids[@]} > 0 )); then
        kill -TERM "${worker_pids[@]}" 2>/dev/null || true
    fi
    exit 143
}

trap_exit() {
    local exit_status=$?
    terminate_active_processes
    if (( ${#worker_pids[@]} > 0 )); then
        local worker_pid
        for worker_pid in "${worker_pids[@]}"; do
            if process_is_live "$worker_pid"; then
                kill -TERM "$worker_pid" 2>/dev/null || true
                wait_for_owned_process "$worker_pid" "$TERM_GRACE" || {
                    kill -KILL "$worker_pid" 2>/dev/null || true
                    wait_for_owned_process "$worker_pid" "$KILL_GRACE" || true
                }
            fi
            wait "$worker_pid" 2>/dev/null || true
        done
    fi
    if [[ -f "$manifest" && "$manifest_finalized" -eq 0 ]]; then
        if (( interrupted )); then
            finalize_manifest "interrupted"
        else
            finalize_manifest "failed"
        fi
    fi
    if (( fuzz_build_root_temporary )) && [[ -n "$FUZZ_BUILD_ROOT" ]]; then
        rm -rf "$FUZZ_BUILD_ROOT"
    fi
    if (( spm_cache_temporary )) && [[ -n "$SPM_CACHE_DIR" ]]; then
        rm -rf "$SPM_CACHE_DIR"
    fi
    if (( interrupted )); then exit 143; fi
    exit "$exit_status"
}
trap trap_exit EXIT
trap 'trap_signal' TERM INT

if [[ -z "$FUZZ_BUILD_ROOT" ]]; then
    FUZZ_BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/axoloty-fuzz-build.XXXXXX") \
        || die "cannot create temporary fuzz build root"
    fuzz_build_root_temporary=1
else
    mkdir -p "$FUZZ_BUILD_ROOT" || die "cannot create fuzz build root: $FUZZ_BUILD_ROOT"
    FUZZ_BUILD_ROOT=$(cd "$FUZZ_BUILD_ROOT" && pwd)
fi
if [[ -z "$SPM_CACHE_DIR" ]]; then
    SPM_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/axoloty-fuzz-swiftpm.XXXXXX") \
        || die "cannot create temporary SwiftPM cache root"
    spm_cache_temporary=1
else
    mkdir -p "$SPM_CACHE_DIR" || die "cannot create SwiftPM cache root: $SPM_CACHE_DIR"
    SPM_CACHE_DIR=$(cd "$SPM_CACHE_DIR" && pwd)
fi

started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
git_status_json=$(json_escape "$git_status")
cat > "$manifest" <<EOF
{
  "schemaVersion": 1,
  "startedAt": "$(json_escape "$started_at")",
  "gitRevision": "$(json_escape "$git_revision")",
  "gitStatus": "${git_status_json}",
  "root": "$(json_escape "$ROOT_DIR")",
  "hostname": "$(json_escape "$(hostname 2>/dev/null || echo unknown)")",
  "executionMode": "$(json_escape "$MODE")",
  "containerRuntime": "$(json_escape "${RUNTIME:-}")",
  "image": "$(json_escape "$IMAGE")",
  "fuzzBuildRoot": "$(json_escape "$FUZZ_BUILD_ROOT")",
  "swiftpmCacheRoot": "$(json_escape "$SPM_CACHE_DIR")",
  "iterations": $ITERATIONS,
  "seeds": ["$(printf '%s' "$SEEDS" | sed 's/,/","/g')"],
  "repetitions": $REPETITIONS,
  "jobs": $JOBS,
  "buildTimeoutSeconds": $BUILD_TIMEOUT,
  "caseTimeoutSeconds": $CASE_TIMEOUT,
  "termGraceSeconds": $TERM_GRACE,
  "killGraceSeconds": $KILL_GRACE,
  "progressIntervalSeconds": $PROGRESS_INTERVAL,
  "cases": []
}
EOF

printf 'case\tseed\trepetition\titerations\tdurationSeconds\texitStatus\tlog\n' > "$summary"
echo "Fuzz campaign started at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$campaign_log"
((QUIET)) || echo "Fuzz campaign: $campaign_dir (mode=$MODE, iterations=$ITERATIONS, seeds=$SEEDS, repetitions=$REPETITIONS, jobs=$JOBS)"

if [[ "$MODE" == container ]]; then
    ((QUIET)) || echo "Preparing development image: $IMAGE"
    if ! make -C "$ROOT_DIR" image CONTAINER_RUNTIME="$RUNTIME" IMAGE="$IMAGE" \
        SPM_CACHE_DIR="$campaign_dir/swiftpm-cache" 2>&1 | tee -a "$campaign_log"; then
        echo "Container image preparation failed; see $campaign_log" >&2
        exit 1
    fi
fi

scratch_root="$FUZZ_BUILD_ROOT/$(basename "$campaign_dir")"
mkdir -p "$scratch_root" "$campaign_dir/results"

swift_testing_run_is_nonempty() {
    local output="$1"
    awk '
        /✔ Test run with [1-9][0-9]* tests? in .* passed/ { summary = 1 }
        /✔ Test / && $0 !~ /✔ Test run with/ && / passed/ { passed = 1 }
        /➜ Test / && / skipped\./ { skipped = 1 }
        END { exit (passed || (summary && !skipped)) ? 0 : 1 }
    ' "$output"
}

validate_swift_test_output() {
    local output="$1"
    if swift_testing_run_is_nonempty "$output"; then
        return 0
    fi
    {
        echo "fuzz runner rejected a successful Swift test command with no non-skipped Swift Testing execution"
        echo "Swift Testing summary was absent or reported zero tests; an XCTest compatibility zero-test line alone is not sufficient evidence"
    } >> "$output"
    return 65
}

run_bounded_command() {
    local output="$1" label="$2" timeout="$3"
    shift 3
    local pid status=0 timed_out=0 orphaned=0 marker leader_pgid last_progress ownership_deadline
    : > "$output"
    printf 'command:' >> "$output"
    printf ' %q' "$@" >> "$output"
    printf '\n' >> "$output"
    setsid -- "$@" >> "$output" 2>&1 &
    pid=$!
    marker="$active_process_dir/$pid"
    : > "$marker"
    if process_is_live "$pid"; then
        # `setsid` is a separate executable. The shell can publish its PID
        # before it has completed the session transition, so allow that live
        # child a short monotonic handshake instead of sampling its old PGID
        # once and reporting a false ownership failure.
        ownership_deadline=$((SECONDS + 1))
        leader_pgid=""
        while process_is_live "$pid"; do
            leader_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
            [[ "$leader_pgid" == "$pid" ]] && break
            (( SECONDS >= ownership_deadline )) && break
            sleep 0.05
        done
        if process_is_live "$pid" && [[ "$leader_pgid" != "$pid" ]]; then
            echo "[$label] refusing to signal unowned process group: leader pid=$pid pgid=${leader_pgid:-unknown}" >> "$output"
            terminate_leader_bounded "$pid" "$label ownership failure" || true
            rm -f "$marker"
            return 125
        fi
    fi
    local deadline=$((SECONDS + timeout))
    last_progress=$SECONDS
    while owned_process_is_live "$pid"; do
        if ! process_is_live "$pid" && process_group_is_live "$pid"; then
            orphaned=1
            break
        fi
        if (( SECONDS - last_progress >= PROGRESS_INTERVAL )); then
            echo "[$label] still running elapsed=$((SECONDS - (deadline - timeout)))s deadline=${timeout}s" >> "$output"
            echo "[$label] still running elapsed=$((SECONDS - (deadline - timeout)))s deadline=${timeout}s" >> "$campaign_log"
            ((QUIET)) || echo "[$label] still running elapsed=$((SECONDS - (deadline - timeout)))s deadline=${timeout}s" >&2
            last_progress=$SECONDS
        fi
        if (( SECONDS >= deadline )); then
            timed_out=1
            break
        fi
        sleep 0.1
    done
    if ((timed_out)); then
        echo "[$label] deadline exceeded after ${timeout}s; seed/case diagnostics are retained" >> "$output"
        terminate_owned_process "$pid" "$label" || status=125
        (( status == 0 )) && status=124
    else
        wait "$pid" 2>/dev/null || status=$?
        if process_group_is_live "$pid"; then
            if ((orphaned)); then
                echo "[$label] leader exited with descendants still alive; cleaning owned process group" >> "$output"
            else
                echo "[$label] command exited with descendants still alive; cleaning process group" >> "$output"
            fi
            terminate_owned_process "$pid" "$label descendants" || status=125
        fi
    fi
    rm -f "$marker"
    return "$status"
}

run_worker() {
    local worker=$1 case_number=0 seed repetition case_name case_log case_start
    local scratch_host="$scratch_root/worker-$worker"
    local scratch_path="$scratch_host"
    local result_file="$campaign_dir/results/worker-$worker.tsv"
    local worker_status=0 build_status command_status duration result build_log
    local -a build_command command

    if [[ "$MODE" == container ]]; then scratch_path="/workspace/.build/fuzz/$(basename "$campaign_dir")/worker-$worker"; fi
    mkdir -p "$scratch_host"
    if [[ "$MODE" == direct ]]; then
        build_command=(swift build --build-tests --cache-path .swiftpm-cache --disable-automatic-resolution --scratch-path "$scratch_path")
    else
        build_command=("$RUNTIME" run --rm -v "$ROOT_DIR:/workspace" -v "$FUZZ_BUILD_ROOT:/workspace/.build/fuzz" -v "$SPM_CACHE_DIR:/workspace/.swiftpm-cache" -w /workspace
            "$IMAGE" swift build --build-tests --cache-path .swiftpm-cache --disable-automatic-resolution --scratch-path "$scratch_path")
    fi
    build_log="$campaign_dir/logs/worker-$worker-build.log"
    if run_bounded_command "$build_log" "worker=$worker build" "$BUILD_TIMEOUT" "${build_command[@]}"; then
        build_status=0
    else
        build_status=$?
    fi
    cat "$build_log" >> "$campaign_log"
    if ((build_status != 0)); then
        echo "worker=$worker build failed status=$build_status log=logs/$(basename "$build_log")" >> "$campaign_log"
        return "$build_status"
    fi

    for seed in "${SEED_LIST[@]}"; do
        for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
            ((interrupted)) && return 143
            case_number=$((case_number + 1))
            (( (case_number - 1) % JOBS == worker - 1 )) || continue
            case_name=$(printf 'case-%03d-seed-%s-repetition-%03d' "$case_number" "$seed" "$repetition")
            case_name=${case_name//[^a-zA-Z0-9_.-]/_}
            case_log="$campaign_dir/logs/$case_name.log"
            case_start=$SECONDS
            ((QUIET)) || echo "[$case_number] worker=$worker seed=$seed repetition=$repetition starting"
            echo "===== $case_name worker=$worker seed=$seed repetition=$repetition =====" >> "$campaign_log"
            if [[ "$MODE" == direct ]]; then
                command=(env AXOLOTY_FUZZ_ITERATIONS="$ITERATIONS" AXOLOTY_FUZZ_SEED="$seed" swift test --skip-build --cache-path .swiftpm-cache --disable-automatic-resolution --scratch-path "$scratch_path" --filter DeterministicFuzzTests)
            else
                command=("$RUNTIME" run --rm -v "$ROOT_DIR:/workspace" -v "$FUZZ_BUILD_ROOT:/workspace/.build/fuzz" -v "$SPM_CACHE_DIR:/workspace/.swiftpm-cache" -w /workspace
                    -e "AXOLOTY_FUZZ_ITERATIONS=$ITERATIONS" -e "AXOLOTY_FUZZ_SEED=$seed"
                    "$IMAGE" swift test --skip-build --cache-path .swiftpm-cache --disable-automatic-resolution --scratch-path "$scratch_path" --filter DeterministicFuzzTests)
            fi
            if run_bounded_command "$case_log" "$case_name seed=$seed" "$CASE_TIMEOUT" "${command[@]}"; then
                command_status=0
            else
                command_status=$?
            fi
            if ((command_status == 0)) && ! validate_swift_test_output "$case_log"; then
                command_status=65
            fi
            cat "$case_log" >> "$campaign_log"
            duration=$((SECONDS - case_start))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$case_name" "$seed" "$repetition" "$ITERATIONS" "$duration" "$command_status" "logs/$(basename "$case_log")" >> "$result_file"
            ((command_status == 0)) && result=passed || { result=failed; worker_status=1; }
            ((QUIET)) || echo "[$case_number] worker=$worker seed=$seed repetition=$repetition $result (${duration}s)"
            echo "===== $case_name result=$result durationSeconds=$duration =====" >> "$campaign_log"
            if ((command_status != 0 && FAIL_FAST == 1)); then return "$worker_status"; fi
        done
    done
    return "$worker_status"
}

overall_status=0
for ((worker = 1; worker <= JOBS; worker++)); do
    run_worker "$worker" &
    worker_pids+=("$!")
done
for worker_pid in "${worker_pids[@]}"; do
    wait "$worker_pid" || overall_status=1
done
status_text=failed
((overall_status == 0)) && status_text=passed
((interrupted)) && status_text=interrupted
finalize_manifest "$status_text"
echo "Fuzz campaign finished with status $overall_status at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$campaign_log"
((QUIET)) || echo "Campaign artifacts: $campaign_dir"
if ((interrupted)); then exit 143; fi
exit "$overall_status"
