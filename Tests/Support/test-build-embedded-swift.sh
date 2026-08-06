#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

project_dir="$tmp/project"
build_dir="$tmp/build"
export_dir="$tmp/export"
idf_dir="$tmp/idf"
bin_dir="$tmp/bin"
log="$tmp/idf.log"
mkdir -p "$project_dir" "$build_dir" "$idf_dir" "$bin_dir"

cat > "$idf_dir/export.sh" <<'SH'
:
SH

cat > "$bin_dir/idf.py" <<'SH'
#!/bin/sh
set -eu
args="$*"
printf '%s\n' "$*" >> "$FAKE_IDF_LOG"
build_dir=
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-B" ]; then
        build_dir=$2
        shift 2
    else
        shift
    fi
done
case "$args" in
    *fullclean*) rm -f "$build_dir/CMakeCache.txt" ;;
    *set-target*) printf '%s\n' 'IDF_TARGET:STRING=esp32c6' 'PYTHON_DEPS_CHECKED:FILEPATH=/opt/esp/tools/python_env/idf5.4_py3.10_env/bin/python' > "$build_dir/CMakeCache.txt" ;;
    *build*)
        if grep -q '/root/.espressif/python_env' "$build_dir/CMakeCache.txt"; then
            echo 'stale Python environment' >&2
            exit 2
        fi
        : > "$build_dir/axoloty-swift.bin"
        ;;
esac
SH
chmod +x "$bin_dir/idf.py"

printf '%s\n' 'IDF_TARGET:STRING=esp32c6' 'PYTHON_DEPS_CHECKED:FILEPATH=/root/.espressif/python_env/idf5.4_py3.10_env/bin/python' > "$build_dir/CMakeCache.txt"

PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_EXPORT_DIR="$export_dir" \
    "$root/Tests/Support/build-embedded-swift.sh"

grep -Fqx -- "-B $build_dir fullclean" "$log"
grep -Fqx -- "-B $build_dir set-target esp32c6" "$log"
grep -Fqx -- "-B $build_dir build" "$log"
test -f "$export_dir/axoloty-swift.bin"
echo 'embedded build cache recovery self-test: OK'
