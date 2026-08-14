#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Incremental ESP32-C6 Embedded Swift build. `idf.py set-target` performs a
# full clean, so invoke it only for a new or mismatched external build tree.

set -eu

project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_dir=${EMBEDDED_BUILD_DIR:-/workspace/.build/embedded-swift}
export_dir=${EMBEDDED_EXPORT_DIR:-/workspace/.build-output/embedded-swift}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

idf_export_log=$(mktemp)
trap 'rm -f "$idf_export_log"' EXIT
set +e
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >"$idf_export_log" 2>&1
idf_export_status=$?
set -e
if [ "$idf_export_status" -ne 0 ]; then
    echo "error: ESP-IDF environment activation failed" >&2
    cat "$idf_export_log" >&2
    echo "hint: run 'make embedded-toolchain-doctor' for environment diagnostics" >&2
    exit 1
fi
rm -f "$idf_export_log"
trap - EXIT
cd "$project_dir"

. "$root/Tests/Support/embedded-build-cache.sh"
axoloty_enable_esp_idf_ccache "$project_dir" esp32c6 firmware
axoloty_print_esp_idf_ccache_stats before
axoloty_prepare_esp_idf_build "$build_dir" esp32c6 0 firmware
idf.py -B "$build_dir" build
axoloty_print_esp_idf_ccache_stats after

# The shared build cache is volatile. Keep the flashable firmware in a
# repository-local ignored directory as durable output.
mkdir -p "$export_dir"
cp "$build_dir/axoloty-swift.bin" "$export_dir/axoloty-swift.bin"
