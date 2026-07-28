#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Incremental ESP32-C6 Embedded Swift build. `idf.py set-target` performs a
# full clean, so invoke it only for a new or mismatched external build tree.

set -eu

project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_dir=${EMBEDDED_BUILD_DIR:-/workspace/.build/embedded-swift}
export_dir=${EMBEDDED_EXPORT_DIR:-/workspace/.build-output/embedded-swift}

. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
cd "$project_dir"

cache="$build_dir/CMakeCache.txt"
if [ ! -f "$cache" ] || ! grep -q '^IDF_TARGET:STRING=esp32c6$' "$cache"; then
    idf.py -B "$build_dir" set-target esp32c6
fi
idf.py -B "$build_dir" build

# The shared build cache is volatile. Keep the flashable firmware in a
# repository-local ignored directory as durable output.
mkdir -p "$export_dir"
cp "$build_dir/axoloty-swift.bin" "$export_dir/axoloty-swift.bin"
