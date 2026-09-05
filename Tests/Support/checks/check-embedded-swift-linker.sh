#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Regression check for the Embedded Swift UnicodeDataTables/.got.plt linker
# integration. Runs inside the development container; no device is required.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
project="$root/Embedded/swift"
jobs=${AXOLOTY_EMBEDDED_LINKER_JOBS:-2}
clean=${AXOLOTY_EMBEDDED_LINKER_CLEAN:-0}

case "$jobs" in
    ''|*[!0-9]*)
        echo "AXOLOTY_EMBEDDED_LINKER_JOBS must be a positive integer no greater than 64" >&2
        exit 1
        ;;
esac
if [ "$jobs" -lt 1 ] || [ "$jobs" -gt 64 ]; then
    echo "AXOLOTY_EMBEDDED_LINKER_JOBS must be a positive integer no greater than 64" >&2
    exit 1
fi

idf_log=$(mktemp)
report_failure() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "EMBEDDED SWIFT LINKER FAIL: ESP-IDF command failed" >&2
        if [ -s "$idf_log" ]; then
            echo "--- captured ESP-IDF output ---" >&2
            cat "$idf_log" >&2
        fi
        if [ -n "${build_dir:-}" ] && [ -d "$build_dir/log" ]; then
            for log in "$build_dir"/log/*; do
                if [ -f "$log" ]; then
                    echo "--- $log ---" >&2
                    cat "$log" >&2
                fi
            done
        fi
    fi
    rm -f "$idf_log"
    exit "$status"
}
trap report_failure EXIT

. "${IDF_PATH:-/opt/esp/idf}/export.sh" >"$idf_log" 2>&1
cd "$project"

. "$root/Tests/Support/embedded/embedded-build-cache.sh"
config_flags=unicode-linker-probe
config_key=$(axoloty_esp_idf_cache_key esp32c6 "$config_flags")
build_dir=${AXOLOTY_EMBEDDED_LINKER_BUILD_DIR:-/workspace/.build/embedded-swift-linker/$config_key}
axoloty_enable_esp_idf_ccache "$project" esp32c6 "$config_flags"
axoloty_print_esp_idf_ccache_stats before
axoloty_prepare_esp_idf_build "$build_dir" esp32c6 "$clean" "$config_flags" \
    -DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON >"$idf_log" 2>&1
IDF_PY_BUILD_JOBS="$jobs" idf.py -B "$build_dir" \
    -DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON build >"$idf_log" 2>&1
if [ "${AXOLOTY_TIMING_EVIDENCE:-0}" = 1 ]; then
    cat "$idf_log"
fi
axoloty_print_esp_idf_ccache_stats after

elf="$build_dir/axoloty-swift.elf"
map="$build_dir/axoloty-swift.map"
sections="$build_dir/esp-idf/esp_system/ld/sections.ld"

test -f "$elf"
test -f "$map"
test -f "$sections"

nm_tool=${RISCV_NM:-riscv32-esp-elf-nm}
"$nm_tool" "$elf" | grep -q ' [TDR] _swift_stdlib_getNormData$'
"$nm_tool" "$elf" | grep -q ' [TDR] axoloty_unicode_linker_probe$'
grep -q 'libswiftUnicodeDataTables.a' "$map"
grep -q '\*(\.got \.got\.\* \.got\.plt \.got\.plt\.\*)' "$sections"
grep -q 'Swift UnicodeDataTables requires \.got/\.got\.plt' "$sections"
if grep -Eiq 'discarded output section.*\.got|orphan.*\.got' "$build_dir/log/"* 2>/dev/null; then
    echo "EMBEDDED SWIFT LINKER FAIL: GOT/PLT was discarded or orphaned" >&2
    exit 1
fi

echo "EMBEDDED SWIFT LINKER OK"
