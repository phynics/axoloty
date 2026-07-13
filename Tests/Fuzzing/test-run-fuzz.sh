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
exit 0
EOF
chmod +x "$fake_runtime"

FAKE_RUNTIME_LOG="$runtime_log" \
  "$ROOT_DIR/Tests/Fuzzing/run-fuzz.sh" \
    --runtime "$fake_runtime" \
    --container \
    --iterations 1 \
    --seeds 1,2 \
    --repetitions 2 \
    --output "$TEMP_DIR/output" \
    --quiet

build_count=$(grep -cF 'swift build --build-tests --scratch-path' "$runtime_log" || true)
test_count=$(grep -cF 'swift test --skip-build --scratch-path' "$runtime_log" || true)

[[ "$build_count" -eq 2 ]]
[[ "$test_count" -eq 4 ]]
grep -qF '"jobs": 2' "$TEMP_DIR"/output/fuzz-*/manifest.json

if grep -qF 'swift test --skip-build --filter DeterministicFuzzTests' "$runtime_log"; then
    echo 'fuzz test command omitted its isolated scratch path' >&2
    exit 1
fi

if grep -qF 'swift test --filter DeterministicFuzzTests' "$runtime_log"; then
    echo 'unexpected build-capable fuzz test command' >&2
    exit 1
fi
