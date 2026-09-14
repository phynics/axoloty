#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Incremental ESP32-C6 Embedded Swift build. `idf.py set-target` performs a
# full clean, so invoke it only for a new or mismatched external build tree.

set -eu

project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_dir=${EMBEDDED_BUILD_DIR:-/workspace/.build/embedded-swift}
sdkconfig="$build_dir/sdkconfig"
export_dir=${EMBEDDED_EXPORT_DIR:-/workspace/.build-output/embedded-swift}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

# Resolve the Core checkout before ESP-IDF starts. The firmware project is
# intentionally allowed to live in a copied or otherwise unrelated tree; all
# portable source, dependency, and macro paths cross this explicit boundary.
AXOLOTY_EMBEDDED_CORE_TOOLS_NO_EXEC=1 . "$support_dir/prepare-embedded-core-tools.sh"
embedded_core_prepare_tools "$build_dir" "$support_dir/resolve-embedded-core.sh"

printf 'Embedded Core: source=%s sha=%s dirty=%s\n' \
    "$AXOLOTY_SOURCE_DIR" "$AXOLOTY_CORE_SHA" "$AXOLOTY_CORE_DIRTY"
printf 'Embedded Core tools: json=%s macro=%s scratch=%s\n' \
    "$AXOLOTY_JSON_CORE_SOURCE_DIR" "$AXOLOTY_STATIC_RUNTIME_MACRO_TOOL" \
    "$AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR"

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

. "$root/Tests/Support/embedded/embedded-build-cache.sh"
axoloty_enable_esp_idf_ccache "$project_dir" esp32c6 firmware
axoloty_print_esp_idf_ccache_stats before
axoloty_prepare_esp_idf_build \
    "$build_dir" esp32c6 0 "firmware:$AXOLOTY_CORE_SHA:$AXOLOTY_CORE_DIRTY" \
    -D SDKCONFIG="$sdkconfig"
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build
axoloty_print_esp_idf_ccache_stats after

# The shared build cache is volatile. Keep the flashable firmware in a
# repository-local ignored directory as durable output.
mkdir -p "$export_dir"
cp "$build_dir/axoloty-swift.bin" "$export_dir/axoloty-swift.bin"
