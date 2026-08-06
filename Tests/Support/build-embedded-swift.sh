#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Incremental ESP32-C6 Embedded Swift build. `idf.py set-target` performs a
# full clean, so invoke it only for a new or mismatched external build tree.

set -eu

project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_dir=${EMBEDDED_BUILD_DIR:-/workspace/.build/embedded-swift}
export_dir=${EMBEDDED_EXPORT_DIR:-/workspace/.build-output/embedded-swift}

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

cache="$build_dir/CMakeCache.txt"
active_python_root="${IDF_TOOLS_PATH:-${HOME:-/root}/.espressif}/python_env/"
if [ -f "$cache" ] && grep -q 'PYTHON.*python_env' "$cache" && ! grep -Fq "$active_python_root" "$cache"; then
    idf.py -B "$build_dir" fullclean
fi
if [ ! -f "$cache" ] || ! grep -q '^IDF_TARGET:STRING=esp32c6$' "$cache"; then
    idf.py -B "$build_dir" set-target esp32c6
fi
idf.py -B "$build_dir" build

# The shared build cache is volatile. Keep the flashable firmware in a
# repository-local ignored directory as durable output.
mkdir -p "$export_dir"
cp "$build_dir/axoloty-swift.bin" "$export_dir/axoloty-swift.bin"
