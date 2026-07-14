#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

runtime_log="$TEMP_DIR/runtime.log"
fake_runtime="$TEMP_DIR/fake-runtime"

cat > "$fake_runtime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${FAKE_RUNTIME_LOG}"
printf '\n' >> "${FAKE_RUNTIME_LOG}"
if [[ "$*" == *'swift test'* && -n "${FAKE_RUNTIME_SLEEP_SECONDS:-}" ]]; then
    sleep "${FAKE_RUNTIME_SLEEP_SECONDS}"
fi
if [[ "$*" == *'swift test'* ]]; then
    exit "${FAKE_RUNTIME_EXIT_CODE:-0}"
else
    exit 0
fi
EOF
chmod +x "$fake_runtime"

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

# Success path: a complete bounded campaign finalizes the manifest with a passed status.
rm -f "$runtime_log"
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=0 \
  "$ROOT_DIR/Tests/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 1,2 \
    --repetitions 2 \
    --output "$TEMP_DIR/output-success" \
    --quiet

build_count=$(grep -cF 'swift build --build-tests --scratch-path' "$runtime_log" || true)
test_count=$(grep -cF 'swift test --skip-build --scratch-path' "$runtime_log" || true)

[[ "$build_count" -eq 2 ]]
[[ "$test_count" -eq 4 ]]
manifest_s=$(manifest_path "$TEMP_DIR/output-success")
[[ -f "$manifest_s" ]]
grep -qF '"jobs": 2' "$manifest_s"
grep -qF '"status": "passed"' "$manifest_s"

if grep -qF 'swift test --skip-build --filter DeterministicFuzzTests' "$runtime_log"; then
    echo 'fuzz test command omitted its isolated scratch path' >&2
    exit 1
fi

if grep -qF 'swift test --filter DeterministicFuzzTests' "$runtime_log"; then
    echo 'unexpected build-capable fuzz test command' >&2
    exit 1
fi

# Failure path: a deliberately failing campaign finalizes the manifest with a failed status
# and preserves per-case data consistent with the summary.tsv rows.
rm -f "$runtime_log"
set +e
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=1 \
  "$ROOT_DIR/Tests/Fuzzing/run-fuzz.sh" \
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

# Interruption path: a controlled signal terminates the campaign and the manifest is
# still finalized with an explicit interrupted status and whatever case data was recorded.
rm -f "$runtime_log"
FAKE_RUNTIME_LOG="$runtime_log" \
FAKE_RUNTIME_EXIT_CODE=0 \
FAKE_RUNTIME_SLEEP_SECONDS=0.1 \
  "$ROOT_DIR/Tests/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 1,2,3,4,5 \
    --repetitions 2 \
    --jobs 1 \
    --output "$TEMP_DIR/output-interrupt" \
    --quiet &
run_fuzz_pid=$!

found=0
for _ in $(seq 1 50); do
    for f in "$TEMP_DIR"/output-interrupt/fuzz-*/results/worker-*.tsv; do
        if [[ -f "$f" ]]; then
            found=1
            break 2
        fi
    done
    sleep 0.1
done

kill -TERM "$run_fuzz_pid" || true
set +e
wait "$run_fuzz_pid"
interrupt_status=$?
set -e

[[ "$interrupt_status" -ne 0 ]]
manifest_i=$(manifest_path "$TEMP_DIR/output-interrupt")
[[ -f "$manifest_i" ]]
grep -qF '"status": "interrupted"' "$manifest_i"
grep -qF '"finishedAt"' "$manifest_i"
grep -qF '"durationSeconds"' "$manifest_i"
grep -qF '"caseCount"' "$manifest_i"
if grep -qF '"cases": []' "$manifest_i"; then
    echo 'interrupted manifest has an empty cases array' >&2
    exit 1
fi
