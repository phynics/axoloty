#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for the device wire benchmark orchestration (issue #302).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
pass=0
fail_count=0

check() {
    desc=$1
    shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail_count=$((fail_count + 1))
    fi
}

check "check-benchmark-wire-device.sh passes sh -n" sh -n "$SCRIPT_DIR/../checks/check-benchmark-wire-device.sh"

check "benchmark_main.c exists" test -f "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark_main.c has copyright header" grep -q "Copyright (c) 2026 Atakan DULKER" "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark CMakeLists.txt exists" test -f "$SCRIPT_DIR/../../../Embedded/benchmark/CMakeLists.txt"

check "benchmark sdkconfig.defaults targets esp32c6" grep -q 'CONFIG_IDF_TARGET="esp32c6"' "$SCRIPT_DIR/../../../Embedded/benchmark/sdkconfig.defaults"

check "benchmark emits JSON Lines format" grep -q 'ESP_LOGI.*{' "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark measures topicParse" grep -q 'topicParse' "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark measures dtoDecode" grep -q 'dtoDecode' "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark tests size limits" grep -q 'size-limits' "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark tests sustained rate" grep -q 'sustained-rate' "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark reports heap" grep -q 'free_heap' "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

check "benchmark reports stack high-water" grep -q 'stack_high_water' "$SCRIPT_DIR/../../../Embedded/benchmark/main/benchmark_main.c"

echo
echo "SELF-TEST OK ($pass checks passed, $fail_count failed)"
[ "$fail_count" -eq 0 ] || exit 1
