#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

runtime_log="$TEMP_DIR/runtime.log"
fake_runtime="$TEMP_DIR/fake-runtime"
resolved_hash=$(sha256sum "$ROOT_DIR/Package.resolved")

cat > "$fake_runtime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Build the whole log line in memory, then write it with a single buffered
# printf so concurrent worker invocations cannot interleave their args and
# newline onto one line (which made the test's `grep -c` undercount builds
# and tests ~1 run in 10).
log_line=$(printf '%q ' "$@")
printf '%s\n' "$log_line" >> "${FAKE_RUNTIME_LOG}"
if [[ "$*" == *'swift test'* && -n "${FAKE_RUNTIME_SLEEP_SECONDS:-}" ]]; then
    sleep "${FAKE_RUNTIME_SLEEP_SECONDS}"
fi
if [[ "$*" == *'swift test'* && "${FAKE_RUNTIME_HOSTILE_CHILD:-0}" == 1 ]]; then
    (trap '' TERM INT; while :; do sleep 1; done) &
    hostile_pid=$!
    printf '%s\n' "$hostile_pid" > "${FAKE_RUNTIME_HOSTILE_PID_FILE}"
    trap '' TERM INT
    while :; do sleep 1; done
fi
if [[ "$*" == *'swift build'* && "${FAKE_RUNTIME_HOSTILE_BUILD:-0}" == 1 ]]; then
    (trap '' TERM INT; while :; do sleep 1; done) &
    hostile_pid=$!
    printf '%s\n' "$hostile_pid" > "${FAKE_RUNTIME_HOSTILE_PID_FILE}"
    trap '' TERM INT
    while :; do sleep 1; done
fi
if [[ "$*" == *'swift test'* && "${FAKE_RUNTIME_ORPHAN_CHILD:-0}" == 1 ]]; then
    (trap '' TERM INT; while :; do sleep 1; done) &
    orphan_pid=$!
    printf '%s\n' "$orphan_pid" > "${FAKE_RUNTIME_HOSTILE_PID_FILE}"
fi
if [[ "$*" == *'swift test'* ]]; then
    if [[ "${FAKE_RUNTIME_EMPTY:-0}" == 1 ]]; then
        printf 'warning: No matching test cases were run\n' >&2
        printf '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.\n'
        exit "${FAKE_RUNTIME_EXIT_CODE:-0}"
    fi
    if [[ "${FAKE_RUNTIME_XCTEST_ZERO_LINE:-0}" == 1 ]]; then
        printf 'Test run with 0 tests in 0 suites passed after 0.001 seconds.\n'
    fi
    if [[ "${FAKE_RUNTIME_SKIPPED:-0}" == 1 ]]; then
        printf '➜ Test fuzzCase() skipped.\n'
    fi
    printf '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\n'
    exit "${FAKE_RUNTIME_EXIT_CODE:-0}"
else
    exit 0
fi
EOF
chmod +x "$fake_runtime"

# Used only by the ownership-failure regression below: every normal ps query
# and every build-process query is delegated to the host tool, while the Swift
# test leader's PGID query returns an invalid value. The runner must then use
# bounded leader-only cleanup and never signal the unvalidated group.
fake_ps_dir="$TEMP_DIR/fake-ps-bin"
mkdir -p "$fake_ps_dir"
real_ps=$(command -v ps)
cat > "$fake_ps_dir/ps" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"-o pgid="* ]]; then
    target_pid=""
    for ((index = 1; index <= \$#; index++)); do
        if [[ "\${!index}" == -p ]]; then
            next_index=\$((index + 1))
            target_pid="\${!next_index:-}"
            break
        fi
    done
    target_command=\$("$real_ps" -o args= -p "\$target_pid" 2>/dev/null || true)
    if [[ "\$target_command" == *"swift test"* ]]; then
        printf '999999\\n'
        exit 0
    fi
fi
exec "$real_ps" "\$@"
EOF
chmod +x "$fake_ps_dir/ps"

manifest_path() {
    local dir="$1"
    local path=""
    for f in "$dir"/fuzz-*/manifest.json; do
        if [[ -f "$f" ]]; then
            path="$f"
            break
        fi
    done
    printf '%s' "$path"
}

wait_for_process_bounded() {
    local pid="$1" label="$2" term_grace="${3:-5}" kill_grace="${4:-2}"
    local deadline state

    process_live() {
        state=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' || true)
        [[ -n "$state" && "$state" != Z* ]]
    }

    deadline=$((SECONDS + term_grace))
    while process_live "$pid" && (( SECONDS < deadline )); do
        sleep 0.1
    done
    if process_live "$pid"; then
        echo "[$label] TERM grace expired; sending SIGKILL to pid=$pid" >&2
        kill -KILL "$pid" 2>/dev/null || true
        deadline=$((SECONDS + kill_grace))
        while process_live "$pid" && (( SECONDS < deadline )); do
            sleep 0.1
        done
    fi
    if process_live "$pid"; then
        echo "[$label] cleanup failed: pid=$pid remained alive after SIGKILL" >&2
        return 125
    fi
    local wait_status=0
    wait "$pid" 2>/dev/null || wait_status=$?
    return "$wait_status"
}

# Success path: a complete bounded campaign finalizes the manifest with a passed status.
rm -f "$runtime_log"
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=0 \
AXOLOTY_FUZZ_BUILD_DIR="$TEMP_DIR/external-build" \
SPM_CACHE_DIR="$TEMP_DIR/external-swiftpm-cache" \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 1,2 \
    --repetitions 2 \
    --output "$TEMP_DIR/output-success" \
    --quiet

build_count=$(grep -cF 'swift build --build-tests ' "$runtime_log" || true)
test_count=$(grep -cF 'swift test --skip-build ' "$runtime_log" || true)

[[ "$build_count" -eq 2 ]]
[[ "$test_count" -eq 4 ]]
manifest_s=$(manifest_path "$TEMP_DIR/output-success")
[[ -f "$manifest_s" ]]
grep -qF '"jobs": 2' "$manifest_s"
grep -qF '"status": "passed"' "$manifest_s"
grep -qF '"fuzzBuildRoot": "'"$TEMP_DIR"'/external-build"' "$manifest_s"
grep -qF '"swiftpmCacheRoot": "'"$TEMP_DIR"'/external-swiftpm-cache"' "$manifest_s"
grep -qF "$TEMP_DIR/external-build:/workspace/.build/fuzz" "$runtime_log"

if grep -qF 'swift test --skip-build --filter DeterministicFuzzTests' "$runtime_log"; then
    echo 'fuzz test command omitted its isolated scratch path' >&2
    exit 1
fi

if grep -qF 'swift test --filter DeterministicFuzzTests' "$runtime_log"; then
    echo 'unexpected build-capable fuzz test command' >&2
    exit 1
fi
grep -qF -- '--cache-path .swiftpm-cache --disable-automatic-resolution' "$runtime_log"
grep -qF -- '-v '"$TEMP_DIR/external-swiftpm-cache"':/workspace/.swiftpm-cache' "$runtime_log"
[[ "$(sha256sum "$ROOT_DIR/Package.resolved")" == "$resolved_hash" ]]

# The XCTest compatibility line is allowed when the Swift Testing summary proves
# that a real nonzero Swift Testing run executed.
rm -f "$runtime_log"
env -u BUILD_DIR -u SPM_CACHE_DIR \
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=0 \
FAKE_RUNTIME_XCTEST_ZERO_LINE=1 \
TMPDIR="$TEMP_DIR" \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 1 \
    --repetitions 1 \
    --output "$TEMP_DIR/output-compatibility" \
    --quiet
manifest_c=$(manifest_path "$TEMP_DIR/output-compatibility")
grep -qF '"status": "passed"' "$manifest_c"
grep -Eq "$TEMP_DIR/axoloty-fuzz-build\.[^: ]*:/workspace/.build/fuzz" "$runtime_log"
grep -Eq "$TEMP_DIR/axoloty-fuzz-swiftpm\.[^: ]*:/workspace/.swiftpm-cache" "$runtime_log"

# A successful process that only reports an empty selection is a failed fuzz
# case, even though Swift itself returned zero.
rm -f "$runtime_log"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EMPTY=1 \
FAKE_RUNTIME_EXIT_CODE=0 \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 3 \
    --repetitions 1 \
    --output "$TEMP_DIR/output-empty" \
    --quiet
empty_status=$?
set -e
[[ "$empty_status" -ne 0 ]]
manifest_e=$(manifest_path "$TEMP_DIR/output-empty")
grep -qF '"status": "failed"' "$manifest_e"
grep -qF $'\t65\t' "$TEMP_DIR/output-empty"/*/summary.tsv

# A positive summary containing only skipped tests is not real fuzz execution.
rm -f "$runtime_log"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_SKIPPED=1 \
FAKE_RUNTIME_EXIT_CODE=0 \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 4 \
    --repetitions 1 \
    --output "$TEMP_DIR/output-skipped" \
    --quiet
skipped_status=$?
set -e
[[ "$skipped_status" -ne 0 ]]
grep -qF $'\t65\t' "$TEMP_DIR/output-skipped"/*/summary.tsv

# Failure path: a deliberately failing campaign finalizes the manifest with a failed status
# and preserves per-case data consistent with the summary.tsv rows.
rm -f "$runtime_log"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=1 \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 1,2 \
    --repetitions 2 \
    --output "$TEMP_DIR/output-failure" \
    --quiet
failure_status=$?
set -e

[[ "$failure_status" -ne 0 ]]
manifest_f=$(manifest_path "$TEMP_DIR/output-failure")
[[ -f "$manifest_f" ]]
grep -qF '"status": "failed"' "$manifest_f"
grep -qF '"caseCount": 4' "$manifest_f"
grep -qF '"passedCases": 0' "$manifest_f"
grep -qF '"failedCases": 4' "$manifest_f"
if grep -qF '"cases": []' "$manifest_f"; then
    echo 'failure manifest has an empty cases array' >&2
    exit 1
fi
summary_f="$TEMP_DIR/output-failure"/*/summary.tsv
[[ "$(grep -c 'case-' $summary_f)" -eq 4 ]]

# A TERM-resistant command and child must be contained by the case deadline and
# process-group cleanup. The marker lets this self-test prove the hostile child
# did not survive the campaign.
hostile_pid_file="$TEMP_DIR/hostile-child.pid"
rm -f "$runtime_log" "$hostile_pid_file"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=0 \
FAKE_RUNTIME_HOSTILE_CHILD=1 \
FAKE_RUNTIME_HOSTILE_PID_FILE="$hostile_pid_file" \
AXOLOTY_FUZZ_PROGRESS_INTERVAL_SECONDS=1 \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 7 \
    --repetitions 1 \
    --jobs 1 \
    --case-timeout 2 \
    --term-grace 1 \
    --kill-grace 1 \
    --output "$TEMP_DIR/output-hostile" \
    --quiet
hostile_status=$?
set -e
[[ "$hostile_status" -ne 0 ]]
manifest_h=$(manifest_path "$TEMP_DIR/output-hostile")
grep -qF '"status": "failed"' "$manifest_h"
grep -qF $'\t124\t' "$TEMP_DIR/output-hostile"/*/summary.tsv
grep -qF 'still running elapsed=' "$TEMP_DIR/output-hostile"/*/campaign.log
if [[ -s "$hostile_pid_file" ]]; then
    hostile_pid=$(cat "$hostile_pid_file")
    if kill -0 "$hostile_pid" 2>/dev/null && [[ "$(ps -o stat= -p "$hostile_pid" 2>/dev/null | tr -d ' ')" != Z* ]]; then
        echo "hostile fuzz child survived bounded cleanup: pid=$hostile_pid" >&2
        exit 1
    fi
fi

# The same containment applies to a worker's build before any seed is run.
hostile_build_pid_file="$TEMP_DIR/hostile-build-child.pid"
rm -f "$runtime_log" "$hostile_build_pid_file"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_HOSTILE_BUILD=1 \
FAKE_RUNTIME_HOSTILE_PID_FILE="$hostile_build_pid_file" \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 8 \
    --repetitions 1 \
    --jobs 1 \
    --build-timeout 1 \
    --term-grace 1 \
    --kill-grace 1 \
    --output "$TEMP_DIR/output-hostile-build" \
    --quiet
hostile_build_status=$?
set -e
[[ "$hostile_build_status" -ne 0 ]]
manifest_b=$(manifest_path "$TEMP_DIR/output-hostile-build")
grep -qF '"status": "failed"' "$manifest_b"
grep -qF 'worker=1 build' "$TEMP_DIR/output-hostile-build"/*/campaign.log
if [[ -s "$hostile_build_pid_file" ]]; then
    hostile_build_pid=$(cat "$hostile_build_pid_file")
    if kill -0 "$hostile_build_pid" 2>/dev/null && [[ "$(ps -o stat= -p "$hostile_build_pid" 2>/dev/null | tr -d ' ')" != Z* ]]; then
        echo "hostile build child survived bounded cleanup: pid=$hostile_build_pid" >&2
        exit 1
    fi
fi

# An invalid PGID must fail closed without an unbounded TERM-resistant leader
# wait or group signal. The child is cleaned directly by this self-test because
# the runner intentionally refuses to signal a group whose ownership it cannot
# prove.
invalid_pgid_pid_file="$TEMP_DIR/invalid-pgid-child.pid"
rm -f "$runtime_log" "$invalid_pgid_pid_file"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_HOSTILE_CHILD=1 \
FAKE_RUNTIME_HOSTILE_PID_FILE="$invalid_pgid_pid_file" \
  PATH="$fake_ps_dir:$PATH" \
  timeout 10s "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 10 \
    --repetitions 1 \
    --jobs 1 \
    --case-timeout 1 \
    --term-grace 1 \
    --kill-grace 1 \
    --output "$TEMP_DIR/output-invalid-pgid" \
    --quiet
invalid_pgid_status=$?
set -e
[[ "$invalid_pgid_status" -ne 0 ]]
grep -qF 'refusing to signal unowned process group' "$TEMP_DIR/output-invalid-pgid"/*/campaign.log
grep -qF $'\t125\t' "$TEMP_DIR/output-invalid-pgid"/*/summary.tsv
if [[ -s "$invalid_pgid_pid_file" ]]; then
    invalid_pgid_child=$(cat "$invalid_pgid_pid_file")
    kill -KILL "$invalid_pgid_child" 2>/dev/null || true
fi

# A command that exits cleanly must still have its owned descendant group reaped.
orphan_pid_file="$TEMP_DIR/orphan-child.pid"
rm -f "$runtime_log" "$orphan_pid_file"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_ORPHAN_CHILD=1 \
FAKE_RUNTIME_HOSTILE_PID_FILE="$orphan_pid_file" \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 9 \
    --repetitions 1 \
    --output "$TEMP_DIR/output-orphan" \
    --quiet
orphan_status=$?
set -e
if [[ "$orphan_status" -ne 0 ]]; then
    echo "orphan cleanup campaign failed unexpectedly: status=$orphan_status" >&2
    exit 1
fi
manifest_o=$(manifest_path "$TEMP_DIR/output-orphan")
if [[ ! -f "$manifest_o" ]] || ! grep -qF '"status": "passed"' "$manifest_o"; then
    echo "orphan cleanup campaign did not produce a passed manifest: ${manifest_o:-missing}" >&2
    exit 1
fi
if [[ -s "$orphan_pid_file" ]]; then
    orphan_pid=$(cat "$orphan_pid_file")
    if kill -0 "$orphan_pid" 2>/dev/null && [[ "$(ps -o stat= -p "$orphan_pid" 2>/dev/null | tr -d ' ')" != Z* ]]; then
        echo "orphan fuzz child survived post-exit cleanup: pid=$orphan_pid" >&2
        exit 1
    fi
fi

# Interruption path: a controlled signal terminates the campaign and the manifest is
# still finalized with an explicit interrupted status and whatever case data was recorded.
rm -f "$runtime_log"
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=0 \
FAKE_RUNTIME_SLEEP_SECONDS=5 \
  "$ROOT_DIR/Tests/Support/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 1,2 \
    --repetitions 1 \
    --jobs 1 \
    --output "$TEMP_DIR/output-interrupt" \
    --quiet &
run_fuzz_pid=$!

found=0
for _ in $(seq 1 100); do
    for f in "$TEMP_DIR"/output-interrupt/fuzz-*/results/worker-*.tsv; do
        [[ -f "$f" ]] && grep -q '^case-' "$f" || continue
        for marker in "$TEMP_DIR"/output-interrupt/fuzz-*/active-processes/*; do
            if [[ -f "$marker" ]]; then
                found=1
                break 3
            fi
        done
    done
    sleep 0.1
done

if (( ! found )); then
    kill -TERM "$run_fuzz_pid" 2>/dev/null || true
    set +e
    wait_for_process_bounded "$run_fuzz_pid" "interrupt readiness self-test" 15 5
    set -e
    echo 'fuzz campaign did not record a case and start its next command before the interruption deadline' >&2
    exit 1
fi

kill -TERM "$run_fuzz_pid" || true
set +e
wait_for_process_bounded "$run_fuzz_pid" "interrupt self-test" 15 5
interrupt_status=$?
set -e

if [[ "$interrupt_status" -eq 0 ]]; then
    echo 'interrupted fuzz campaign exited successfully' >&2
    exit 1
fi
manifest_i=$(manifest_path "$TEMP_DIR/output-interrupt")
if [[ ! -f "$manifest_i" ]]; then
    echo 'interrupted fuzz campaign did not produce a manifest' >&2
    exit 1
fi
for field in '"status": "interrupted"' '"finishedAt"' '"durationSeconds"' '"caseCount"'; do
    if ! grep -qF "$field" "$manifest_i"; then
        echo "interrupted fuzz campaign manifest omitted expected field: $field" >&2
        exit 1
    fi
done
if grep -qF '"cases": []' "$manifest_i"; then
    echo 'interrupted manifest has an empty cases array' >&2
    exit 1
fi
