#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ITERATIONS=${AXOLOTY_FUZZ_ITERATIONS:-250}
SEEDS=${AXOLOTY_FUZZ_SEEDS:-${AXOLOTY_FUZZ_SEED:-0x41584f4c4f5459}}
REPETITIONS=${AXOLOTY_FUZZ_REPETITIONS:-1}
JOBS=${AXOLOTY_FUZZ_JOBS:-2}
OUTPUT_BASE=${AXOLOTY_FUZZ_OUTPUT_DIR:-"$ROOT_DIR/.testing/fuzz"}
RUNTIME=${CONTAINER_RUNTIME:-}
IMAGE=${IMAGE:-coatyswift-dev}
MODE=auto
FAIL_FAST=0
QUIET=0

usage() {
    cat <<'EOF'
Usage: Tests/Fuzzing/run-fuzz.sh [options]

Run deterministic Swift Testing fuzz cases and retain an auditable campaign record.

Options:
  --iterations N       Fuzz iterations per case (default: 250)
  --seeds LIST         Comma-separated decimal or hexadecimal seeds
  --repetitions N      Runs per seed (default: 1)
  --jobs N             Parallel workers with isolated build artifacts (default: 2)
  --output DIR         Parent directory for timestamped campaign artifacts
  --runtime RUNTIME    podman or docker when running outside a container
  --image IMAGE        Development image (default: coatyswift-dev)
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
        --iterations|--seeds|--repetitions|--jobs|--output|--runtime|--image)
            (($# >= 2)) || die "$1 requires a value"
            case "$1" in
                --iterations) ITERATIONS=$2 ;;
                --seeds) SEEDS=$2 ;;
                --repetitions) REPETITIONS=$2 ;;
                --jobs) JOBS=$2 ;;
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
[[ -n "$SEEDS" ]] || die "seeds must not be empty"

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
start_epoch=$(date +%s)
git_revision=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
git_status=$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r/\\r/g;s/\t/\\t/g'
}

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
  "iterations": $ITERATIONS,
  "seeds": ["$(printf '%s' "$SEEDS" | sed 's/,/","/g')"],
  "repetitions": $REPETITIONS,
  "jobs": $JOBS,
  "cases": []
}
EOF

printf 'case\tseed\trepetition\titerations\tdurationSeconds\texitStatus\tlog\n' > "$summary"
echo "Fuzz campaign started at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$campaign_log"
((QUIET)) || echo "Fuzz campaign: $campaign_dir (mode=$MODE, iterations=$ITERATIONS, seeds=$SEEDS, repetitions=$REPETITIONS, jobs=$JOBS)"

if [[ "$MODE" == container ]]; then
    ((QUIET)) || echo "Preparing development image: $IMAGE"
    if ! make -C "$ROOT_DIR" image CONTAINER_RUNTIME="$RUNTIME" IMAGE="$IMAGE" 2>&1 | tee -a "$campaign_log"; then
        echo "Container image preparation failed; see $campaign_log" >&2
        exit 1
    fi
fi

scratch_root="$ROOT_DIR/.build/fuzz/$(basename "$campaign_dir")"
mkdir -p "$scratch_root" "$campaign_dir/results"

run_worker() {
    local worker=$1 case_number=0 seed repetition case_name case_log case_start
    local scratch_host="$scratch_root/worker-$worker"
    local scratch_path="$scratch_host"
    local result_file="$campaign_dir/results/worker-$worker.tsv"
    local worker_status=0 build_status command_status duration result
    local -a build_command command

    if [[ "$MODE" == container ]]; then scratch_path="/workspace/.build/fuzz/$(basename "$campaign_dir")/worker-$worker"; fi
    mkdir -p "$scratch_host"
    if [[ "$MODE" == direct ]]; then
        build_command=(swift build --build-tests --scratch-path "$scratch_path")
    else
        build_command=("$RUNTIME" run --rm -v "$ROOT_DIR:/workspace" -w /workspace
            "$IMAGE" swift build --build-tests --scratch-path "$scratch_path")
    fi
    {
        printf 'build command:'; printf ' %q' "${build_command[@]}"; printf '\n'
        "${build_command[@]}"
    } 2>&1 | tee -a "$campaign_log"
    build_status=${PIPESTATUS[0]}
    if ((build_status != 0)); then return "$build_status"; fi

    for seed in "${SEED_LIST[@]}"; do
        for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
            case_number=$((case_number + 1))
            (( (case_number - 1) % JOBS == worker - 1 )) || continue
            case_name=$(printf 'case-%03d-seed-%s-repetition-%03d' "$case_number" "$seed" "$repetition")
            case_name=${case_name//[^a-zA-Z0-9_.-]/_}
            case_log="$campaign_dir/logs/$case_name.log"
            case_start=$(date +%s)
            ((QUIET)) || echo "[$case_number] worker=$worker seed=$seed repetition=$repetition starting"
            echo "===== $case_name worker=$worker seed=$seed repetition=$repetition =====" >> "$campaign_log"
            if [[ "$MODE" == direct ]]; then
                command=(env AXOLOTY_FUZZ_ITERATIONS="$ITERATIONS" AXOLOTY_FUZZ_SEED="$seed" swift test --skip-build --scratch-path "$scratch_path" --filter DeterministicFuzzTests)
            else
                command=("$RUNTIME" run --rm -v "$ROOT_DIR:/workspace" -w /workspace
                    -e "AXOLOTY_FUZZ_ITERATIONS=$ITERATIONS" -e "AXOLOTY_FUZZ_SEED=$seed"
                    "$IMAGE" swift test --skip-build --scratch-path "$scratch_path" --filter DeterministicFuzzTests)
            fi
            {
                printf 'command:'; printf ' %q' "${command[@]}"; printf '\n'
                "${command[@]}"
            } 2>&1 | tee "$case_log" | tee -a "$campaign_log"
            command_status=${PIPESTATUS[0]}
            duration=$(($(date +%s) - case_start))
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
declare -a worker_pids
for ((worker = 1; worker <= JOBS; worker++)); do
    run_worker "$worker" &
    worker_pids+=("$!")
done
for worker_pid in "${worker_pids[@]}"; do
    wait "$worker_pid" || overall_status=1
done
find "$campaign_dir/results" -name '*.tsv' -type f -print0 | xargs -0r cat | sort >> "$summary"

end_epoch=$(date +%s)
case_json=$(awk -F '\t' 'NR > 1 {
    if (n++) separator = ",";
    printf "%s{\"case\":\"%s\",\"seed\":\"%s\",\"repetition\":%s,\"iterations\":%s,\"durationSeconds\":%s,\"exitStatus\":%s,\"log\":\"%s\"}", separator, $1, $2, $3, $4, $5, $6, $7
}' "$summary")
case_count=$(awk 'NR > 1 { count++ } END { print count + 0 }' "$summary")
passed_cases=$(awk -F '\t' 'NR > 1 && $6 == 0 { count++ } END { print count + 0 }' "$summary")
failed_cases=$(awk -F '\t' 'NR > 1 && $6 != 0 { count++ } END { print count + 0 }' "$summary")
status_text=failed
((overall_status == 0)) && status_text=passed
finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
sed -i "/  \"cases\": \[\]/c\\  \"status\": \"$status_text\",\n  \"finishedAt\": \"$finished_at\",\n  \"durationSeconds\": $((end_epoch - start_epoch)),\n  \"caseCount\": $case_count,\n  \"passedCases\": $passed_cases,\n  \"failedCases\": $failed_cases,\n  \"cases\": [$case_json]" "$manifest"
echo "Fuzz campaign finished with status $overall_status at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$campaign_log"
((QUIET)) || echo "Campaign artifacts: $campaign_dir"
exit "$overall_status"
