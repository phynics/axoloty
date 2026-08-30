#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The ESP-IDF dependency metadata alone does not order Swift compilation
# behind json_core's importable module alias. Keep the explicit target edge
# covered because its absence fails nondeterministically under parallel Ninja.
wire_cmake="$root/Embedded/swift/components/axoloty_wire/CMakeLists.txt"
json_core_cmake="$root/Embedded/swift/components/json_core/CMakeLists.txt"
static_runtime_cmake="$root/Embedded/swift/components/axoloty_static_runtime/CMakeLists.txt"
grep -Fq 'add_custom_target(json_core_module_alias' "$json_core_cmake"
grep -Fq 'idf_component_get_property(JSON_CORE_COMPONENT_LIB json_core COMPONENT_LIB)' "$wire_cmake"
grep -Fq 'add_dependencies(${COMPONENT_LIB} json_core_module_alias)' "$wire_cmake"
grep -Fq '.build/*/debug/AxolotyStaticRuntimeMacrosImplementation-tool' "$static_runtime_cmake"
grep -Fq '$<$<COMPILE_LANGUAGE:Swift>:-warnings-as-errors>' "$static_runtime_cmake"
grep -Fq '$<$<COMPILE_LANGUAGE:Swift>:-load-plugin-executable>' "$static_runtime_cmake"
grep -Fq '\#AxolotyStaticRuntimeMacrosImplementation' "$static_runtime_cmake"

project_dir="$tmp/project"
build_dir="$tmp/build"
export_dir="$tmp/export"
idf_dir="$tmp/idf"
bin_dir="$tmp/bin"
log="$tmp/idf.log"
mkdir -p "$project_dir" "$build_dir" "$idf_dir" "$bin_dir"

cat > "$idf_dir/export.sh" <<'SH'
export IDF_TOOLS_PATH=/opt/esp/tools
SH

cat > "$bin_dir/idf.py" <<'SH'
#!/bin/sh
set -eu
args="$*"
printf '%s\n' "$*" >> "$FAKE_IDF_LOG"
printf 'IDF_CCACHE_ENABLE=%s CCACHE_DIR=%s CCACHE_NAMESPACE=%s\n' \
    "${IDF_CCACHE_ENABLE:-}" "${CCACHE_DIR:-}" "${CCACHE_NAMESPACE:-}" >> "$FAKE_IDF_ENV_LOG"
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
    *set-target*)
        printf '%s\n' \
            'IDF_TARGET:STRING=esp32c6' \
            'PYTHON_DEPS_CHECKED:FILEPATH=/opt/esp/tools/python_env/idf5.4_py3.10_env/bin/python' \
            "CCACHE_ENABLE:UNINITIALIZED=${IDF_CCACHE_ENABLE:-OFF}" > "$build_dir/CMakeCache.txt"
        ;;
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

cat > "$bin_dir/ccache" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--print-stats" ]; then
    printf 'cache_hit 17\ncache_miss 3\n'
fi
exit 0
SH
chmod +x "$bin_dir/ccache"

printf '%s\n' 'IDF_TARGET:STRING=esp32c6' 'PYTHON_DEPS_CHECKED:FILEPATH=/root/.espressif/python_env/idf5.4_py3.10_env/bin/python' > "$build_dir/CMakeCache.txt"

PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_EXPORT_DIR="$export_dir" \
    "$root/Tests/Support/build-embedded-swift.sh"

grep -Fqx -- "-B $build_dir fullclean" "$log"
grep -Fqx -- "-B $build_dir set-target esp32c6" "$log"
grep -Fqx -- "-B $build_dir build" "$log"
test -f "$export_dir/axoloty-swift.bin"
grep -Fq "IDF_CCACHE_ENABLE=1 CCACHE_DIR=$tmp/ccache CCACHE_NAMESPACE=esp-idf-" "$tmp/idf-env.log"
grep -Fqx 'CCACHE_ENABLE:UNINITIALIZED=1' "$build_dir/CMakeCache.txt"

# A warm build preserves the configuration, but a cache that no longer has
# ccache active must be reconfigured even when target and Python still match.
PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_EXPORT_DIR="$export_dir" \
    "$root/Tests/Support/build-embedded-swift.sh"
test "$(grep -Fc -- "-B $build_dir set-target esp32c6" "$log")" -eq 1

timing_output=$(PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    AXOLOTY_TIMING_EVIDENCE=1 EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EXPORT_DIR="$export_dir" "$root/Tests/Support/build-embedded-swift.sh")
printf '%s\n' "$timing_output" | grep -Fqx 'ccache_before cache_hit 17'
printf '%s\n' "$timing_output" | grep -Fqx 'ccache_after cache_miss 3'

sed -i 's/CCACHE_ENABLE:UNINITIALIZED=1/CCACHE_ENABLE:UNINITIALIZED=OFF/' "$build_dir/CMakeCache.txt"
PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_EXPORT_DIR="$export_dir" \
    "$root/Tests/Support/build-embedded-swift.sh"
test "$(grep -Fc -- "-B $build_dir fullclean" "$log")" -eq 2
test "$(grep -Fc -- "-B $build_dir set-target esp32c6" "$log")" -eq 2
grep -Fqx 'CCACHE_ENABLE:UNINITIALIZED=1' "$build_dir/CMakeCache.txt"

echo 'embedded build cache recovery self-test: OK'
