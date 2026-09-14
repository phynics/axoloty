#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
expected_core_sha=$(git -C "$root" rev-parse --verify HEAD^{commit})
git_dirty_state() {
    if [ -n "$(git -C "$1" status --porcelain --untracked-files=normal)" ]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}
expected_root_dirty=$(git_dirty_state "$root")

# The ESP-IDF dependency metadata alone does not order Swift compilation
# behind json_core's importable module alias. Keep the explicit target edge
# covered because its absence fails nondeterministically under parallel Ninja.
wire_cmake="$root/Embedded/swift/components/axoloty_wire/CMakeLists.txt"
json_core_cmake="$root/Embedded/swift/components/json_core/CMakeLists.txt"
static_runtime_cmake="$root/Embedded/swift/components/axoloty_static_runtime/CMakeLists.txt"
grep -Fq 'add_custom_target(json_core_module_alias' "$json_core_cmake"
grep -Fq 'idf_component_get_property(JSON_CORE_COMPONENT_LIB json_core COMPONENT_LIB)' "$wire_cmake"
grep -Fq 'add_dependencies(${COMPONENT_LIB} json_core_module_alias)' "$wire_cmake"
grep -Fq 'AXOLOTY_STATIC_RUNTIME_MACRO_TOOL' "$static_runtime_cmake"
grep -Fq 'axoloty-source.cmake' "$static_runtime_cmake"
grep -Fq '$<$<COMPILE_LANGUAGE:Swift>:-warnings-as-errors>' "$static_runtime_cmake"
grep -Fq '$<$<COMPILE_LANGUAGE:Swift>:-load-plugin-executable>' "$static_runtime_cmake"
grep -Fq '\#AxolotyStaticRuntimeMacrosImplementation' "$static_runtime_cmake"

project_dir="$tmp/project"
build_dir="$tmp/build"
export_dir="$tmp/export"
idf_dir="$tmp/idf"
bin_dir="$tmp/bin"
log="$tmp/idf.log"
macro_scratch="$tmp/macro-scratch"
macro_tool="$macro_scratch/bin/AxolotyStaticRuntimeMacrosImplementation-tool"
json_core_dir="$macro_scratch/checkouts/swift-json/Sources/_JSONCore"
export FAKE_CCACHE_LOG="$tmp/ccache.log"
mkdir -p "$project_dir" "$build_dir" "$idf_dir" "$bin_dir" "$json_core_dir" "$(dirname "$macro_tool")"
: > "$macro_tool"

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
mkdir -p "$build_dir"
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
if [ -n "${AXOLOTY_SOURCE_DIR:-}" ]; then
    printf '%s\n' \
        "AXOLOTY_SOURCE_DIR=$AXOLOTY_SOURCE_DIR" \
        "AXOLOTY_WIRE_SOURCE_DIR=${AXOLOTY_WIRE_SOURCE_DIR:-}" \
        "AXOLOTY_OBJECT_MODEL_SOURCE_DIR=${AXOLOTY_OBJECT_MODEL_SOURCE_DIR:-}" \
        "AXOLOTY_PROTOCOL_SOURCE_DIR=${AXOLOTY_PROTOCOL_SOURCE_DIR:-}" \
        "AXOLOTY_COATY_MODELS_SOURCE_DIR=${AXOLOTY_COATY_MODELS_SOURCE_DIR:-}" \
        "AXOLOTY_STATIC_RUNTIME_SOURCE_DIR=${AXOLOTY_STATIC_RUNTIME_SOURCE_DIR:-}" \
        "AXOLOTY_JSON_CORE_SOURCE_DIR=${AXOLOTY_JSON_CORE_SOURCE_DIR:-}" \
        "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL=${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL:-}" \
        "AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR=${AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR:-}" \
        "AXOLOTY_CORE_SHA=${AXOLOTY_CORE_SHA:-}" \
        "AXOLOTY_CORE_DIRTY=${AXOLOTY_CORE_DIRTY:-}" \
        > "$build_dir/axoloty-core-env"
fi
SH
chmod +x "$bin_dir/idf.py"

cat > "$bin_dir/ccache" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_CCACHE_LOG:-/dev/null}"
if [ "${1:-}" = "--print-stats" ]; then
    printf 'cache_hit 17\ncache_miss 3\n'
fi
exit 0
SH
chmod +x "$bin_dir/ccache"

cat > "$bin_dir/swift" <<'SH'
#!/bin/sh
set -eu
scratch=
show_bin_path=0
requested_target=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --scratch-path) scratch=$2; shift 2 ;;
        --show-bin-path) show_bin_path=1; shift ;;
        --target) requested_target=$2; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$scratch" ]
mkdir -p "$scratch/bin" "$scratch/checkouts/swift-json/Sources/_JSONCore"
macro="$scratch/bin/AxolotyStaticRuntimeMacrosImplementation-tool"
# SwiftPM compiles a macro target without linking its executable when that
# target is selected directly. Building the consuming package links the tool.
if [ "$show_bin_path" = 0 ] &&
    [ "$requested_target" != AxolotyStaticRuntimeMacrosImplementation ]; then
    : > "$macro"
    chmod +x "$macro"
fi
if [ "$show_bin_path" = 1 ]; then
    printf '%s\n' "$scratch/bin"
fi
SH
chmod +x "$bin_dir/swift"

printf '%s\n' 'IDF_TARGET:STRING=esp32c6' 'PYTHON_DEPS_CHECKED:FILEPATH=/root/.espressif/python_env/idf5.4_py3.10_env/bin/python' > "$build_dir/CMakeCache.txt"

PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    AXOLOTY_SOURCE_DIR="$root" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_EXPORT_DIR="$export_dir" \
    "$root/Tests/Support/embedded/build-embedded-swift.sh"

grep -Fqx -- "-B $build_dir -D SDKCONFIG=$build_dir/sdkconfig fullclean" "$log"
grep -Fqx -- "-B $build_dir -D SDKCONFIG=$build_dir/sdkconfig set-target esp32c6" "$log"
grep -Fqx -- "-B $build_dir -D SDKCONFIG=$build_dir/sdkconfig build" "$log"
test -f "$export_dir/axoloty-swift.bin"
grep -Fq "IDF_CCACHE_ENABLE=1 CCACHE_DIR=$tmp/ccache CCACHE_NAMESPACE=esp-idf-" "$tmp/idf-env.log"
grep -Fqx 'CCACHE_ENABLE:UNINITIALIZED=1' "$build_dir/CMakeCache.txt"
grep -Fqx -- '--max-size 512M' "$tmp/ccache.log"
grep -Fqx "AXOLOTY_SOURCE_DIR=$root" "$build_dir/axoloty-core-env"
grep -Fqx "AXOLOTY_WIRE_SOURCE_DIR=$root/Packages/AxolotyWire/Sources/AxolotyWire" "$build_dir/axoloty-core-env"
grep -Fqx "AXOLOTY_JSON_CORE_SOURCE_DIR=$json_core_dir" "$build_dir/axoloty-core-env"
grep -Fqx "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL=$macro_tool" "$build_dir/axoloty-core-env"
grep -Fqx "AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR=$macro_scratch" "$build_dir/axoloty-core-env"
grep -Fqx "AXOLOTY_CORE_SHA=$expected_core_sha" "$build_dir/axoloty-core-env"
grep -Fqx "AXOLOTY_CORE_DIRTY=$expected_root_dirty" "$build_dir/axoloty-core-env"

# A warm build preserves the configuration, but a cache that no longer has
# ccache active must be reconfigured even when target and Python still match.
PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    AXOLOTY_SOURCE_DIR="$root" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_EXPORT_DIR="$export_dir" \
    "$root/Tests/Support/embedded/build-embedded-swift.sh"
test "$(grep -Fc -- "-B $build_dir -D SDKCONFIG=$build_dir/sdkconfig set-target esp32c6" "$log")" -eq 1

timing_output=$(PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    AXOLOTY_SOURCE_DIR="$root" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    AXOLOTY_TIMING_EVIDENCE=1 EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EXPORT_DIR="$export_dir" "$root/Tests/Support/embedded/build-embedded-swift.sh")
printf '%s\n' "$timing_output" | grep -Fqx 'ccache_before cache_hit 17'
printf '%s\n' "$timing_output" | grep -Fqx 'ccache_after cache_miss 3'

sed -i 's/CCACHE_ENABLE:UNINITIALIZED=1/CCACHE_ENABLE:UNINITIALIZED=OFF/' "$build_dir/CMakeCache.txt"
PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/ccache" \
    AXOLOTY_SOURCE_DIR="$root" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$build_dir" EMBEDDED_EXPORT_DIR="$export_dir" \
    "$root/Tests/Support/embedded/build-embedded-swift.sh"
test "$(grep -Fc -- "-B $build_dir -D SDKCONFIG=$build_dir/sdkconfig fullclean" "$log")" -eq 2
test "$(grep -Fc -- "-B $build_dir -D SDKCONFIG=$build_dir/sdkconfig set-target esp32c6" "$log")" -eq 2
grep -Fqx 'CCACHE_ENABLE:UNINITIALIZED=1' "$build_dir/CMakeCache.txt"

echo 'embedded build cache recovery self-test: OK'

# The resolver is independent of the firmware checkout. Use a local clone in
# an unrelated temporary root to prove that no parent-directory relationship
# or root .build search is required.
resolver="$root/Tests/Support/embedded/resolve-embedded-core.sh"
clean_core="$tmp/unrelated-core"
firmware_copy="$tmp/unrelated-firmware"
git clone --quiet --no-hardlinks "$root" "$clean_core"
mkdir -p "$firmware_copy"
cp -R "$root/Embedded/swift/." "$firmware_copy/"
expected_clean_core_dirty=$(git_dirty_state "$clean_core")

clean_result=$(AXOLOTY_SOURCE_DIR="$clean_core" sh "$resolver")
printf '%s\n' "$clean_result" | grep -Fqx "AXOLOTY_CORE_DIRTY=$expected_clean_core_dirty"
printf '%s\n' "$clean_result" | grep -Fqx "AXOLOTY_CORE_SHA=$expected_core_sha"
syntax_core="$tmp/core;safe"
git clone --quiet --no-hardlinks "$root" "$syntax_core"
syntax_result=$(AXOLOTY_SOURCE_DIR="$syntax_core" sh "$resolver")
printf '%s\n' "$syntax_result" | grep -Fqx "AXOLOTY_SOURCE_DIR=$syntax_core"
printf '%s\n' 'dirty fixture' > "$clean_core/dirty-fixture.txt"
expected_dirty_core_dirty=$(git_dirty_state "$clean_core")
dirty_result=$(AXOLOTY_SOURCE_DIR="$clean_core" sh "$resolver")
printf '%s\n' "$dirty_result" | grep -Fqx "AXOLOTY_CORE_DIRTY=$expected_dirty_core_dirty"

# The reusable ESP-IDF cache key separates Core path, revision, and dirty
# state, so a warm firmware cache cannot silently reuse another checkout.
. "$root/Tests/Support/embedded/embedded-build-cache.sh"
cache_key_for() {
    AXOLOTY_SOURCE_DIR="$1" AXOLOTY_CORE_SHA="$2" AXOLOTY_CORE_DIRTY="$3" \
        axoloty_esp_idf_cache_key esp32c6 firmware
}
path_cache_key=$(cache_key_for "$clean_core" "$expected_core_sha" "$expected_clean_core_dirty")
other_path_cache_key=$(cache_key_for "$root" "$expected_core_sha" "$expected_root_dirty")
dirty_cache_key=$(cache_key_for "$clean_core" "$expected_core_sha" "$expected_dirty_core_dirty")
other_sha_cache_key=$(cache_key_for "$clean_core" "0000000000000000000000000000000000000000" "$expected_clean_core_dirty")
test "$path_cache_key" != "$other_path_cache_key"
test "$path_cache_key" != "$dirty_cache_key"
test "$path_cache_key" != "$other_sha_cache_key"

unrelated_build="$tmp/unrelated-build"
unrelated_export="$tmp/unrelated-export"
PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$tmp/unrelated-idf.log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/unrelated-idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/unrelated-ccache" \
    AXOLOTY_SOURCE_DIR="$clean_core" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    EMBEDDED_PROJECT_DIR="$firmware_copy" EMBEDDED_BUILD_DIR="$unrelated_build" EMBEDDED_EXPORT_DIR="$unrelated_export" \
    "$root/Tests/Support/embedded/build-embedded-swift.sh" >/dev/null
test -f "$unrelated_export/axoloty-swift.bin"

expect_rejection() {
    expected=$1
    shift
    if output=$("$@" 2>&1); then
        echo "expected resolver rejection: $expected" >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -Fq "$expected"
}

baseline_idf_calls=$(wc -l < "$log")
expect_rejection 'AXOLOTY_SOURCE_DIR is required' env -u AXOLOTY_SOURCE_DIR sh "$resolver"
expect_rejection 'AXOLOTY_SOURCE_DIR must be an absolute path' env AXOLOTY_SOURCE_DIR=relative sh "$resolver"
expect_rejection 'AXOLOTY_SOURCE_DIR does not exist' env AXOLOTY_SOURCE_DIR="$tmp/missing-core" sh "$resolver"

escaped_core="$tmp/escaped-core"
git clone --quiet --no-hardlinks "$root" "$escaped_core"
rm -rf "$escaped_core/Packages/AxolotyWire/Sources/AxolotyWire"
mkdir -p "$tmp/outside-source"
ln -s "$tmp/outside-source" "$escaped_core/Packages/AxolotyWire/Sources/AxolotyWire"
expect_rejection 'escapes AXOLOTY_SOURCE_DIR through a symlink' env AXOLOTY_SOURCE_DIR="$escaped_core" sh "$resolver"

missing_package="$tmp/missing-package-core"
git clone --quiet --no-hardlinks "$root" "$missing_package"
rm -rf "$missing_package/Packages/AxolotyProtocol"
expect_rejection 'AXOLOTY_PROTOCOL_SOURCE_DIR does not exist' env AXOLOTY_SOURCE_DIR="$missing_package" sh "$resolver"

missing_manifest="$tmp/missing-manifest-core"
git clone --quiet --no-hardlinks "$root" "$missing_manifest"
rm -f "$missing_manifest/Packages/AxolotyWire/Package.swift"
expect_rejection 'AxolotyWire package manifest is missing' env AXOLOTY_SOURCE_DIR="$missing_manifest" sh "$resolver"

missing_source="$tmp/missing-source-core"
git clone --quiet --no-hardlinks "$root" "$missing_source"
rm -f "$missing_source/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime/StaticRuntime.swift"
expect_rejection 'AXOLOTY_STATIC_RUNTIME_SOURCE_DIR expected source file is missing' env AXOLOTY_SOURCE_DIR="$missing_source" sh "$resolver"
test "$(wc -l < "$log")" -eq "$baseline_idf_calls"

# Two cold firmware-owned build directories may configure concurrently; the
# resolver and build cache must not require a shared Core output directory.
parallel_a="$tmp/parallel-a"
parallel_b="$tmp/parallel-b"
(
    PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$tmp/parallel-a.log" IDF_PATH="$idf_dir" \
        FAKE_IDF_ENV_LOG="$tmp/parallel-a-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/parallel-a-ccache" \
        AXOLOTY_SOURCE_DIR="$clean_core" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
        AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
        EMBEDDED_PROJECT_DIR="$firmware_copy" EMBEDDED_BUILD_DIR="$parallel_a" EMBEDDED_EXPORT_DIR="$tmp/parallel-a-export" \
        "$root/Tests/Support/embedded/build-embedded-swift.sh" >/dev/null
) &
pid_a=$!
(
    PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$tmp/parallel-b.log" IDF_PATH="$idf_dir" \
        FAKE_IDF_ENV_LOG="$tmp/parallel-b-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/parallel-b-ccache" \
        AXOLOTY_SOURCE_DIR="$clean_core" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
        AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
        EMBEDDED_PROJECT_DIR="$firmware_copy" EMBEDDED_BUILD_DIR="$parallel_b" EMBEDDED_EXPORT_DIR="$tmp/parallel-b-export" \
        "$root/Tests/Support/embedded/build-embedded-swift.sh" >/dev/null
) &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
test -f "$tmp/parallel-a-export/axoloty-swift.bin"
test -f "$tmp/parallel-b-export/axoloty-swift.bin"

# With no caller override, each concurrent preparation owns a sibling scratch
# directory outside its ESP-IDF build tree. The fake Swift executable proves
# both preparations fetch the JSON checkout and produce an isolated macro.
auto_prepare() {
    build=$1
    PATH="$bin_dir:$PATH"
    AXOLOTY_SOURCE_DIR="$clean_core"
    export PATH AXOLOTY_SOURCE_DIR
    AXOLOTY_EMBEDDED_CORE_TOOLS_NO_EXEC=1 . "$root/Tests/Support/embedded/prepare-embedded-core-tools.sh"
    embedded_core_prepare_tools "$build" "$root/Tests/Support/embedded/resolve-embedded-core.sh"
    printf '%s\n' "$AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR" > "$build.scratch"
    test -x "$AXOLOTY_STATIC_RUNTIME_MACRO_TOOL"
    test -d "$AXOLOTY_JSON_CORE_SOURCE_DIR"
}
auto_prepare_a="$tmp/auto-a"
auto_prepare_b="$tmp/auto-b"
( auto_prepare "$auto_prepare_a" ) & auto_prepare_pid_a=$!
( auto_prepare "$auto_prepare_b" ) & auto_prepare_pid_b=$!
wait "$auto_prepare_pid_a"
wait "$auto_prepare_pid_b"
scratch_a=$(cat "$auto_prepare_a.scratch")
scratch_b=$(cat "$auto_prepare_b.scratch")
test "$scratch_a" != "$scratch_b"
case "$scratch_a" in "$auto_prepare_a.core-tools") ;; *) exit 1 ;; esac
case "$scratch_b" in "$auto_prepare_b.core-tools") ;; *) exit 1 ;; esac

# Reproducible builds use a caller-owned, dedicated directory and carry the
# same build-local SDKCONFIG through clean and build. An unrelated project is
# sufficient here because the fake ESP-IDF command is the boundary under test.
repro_build_parent="$tmp/repro"
repro_build="$repro_build_parent/embedded-swift-reproducible"
repro_export="$tmp/repro-export"
mkdir -p "$repro_build_parent"
PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    FAKE_IDF_ENV_LOG="$tmp/idf-env.log" AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/repro-ccache" \
    AXOLOTY_SOURCE_DIR="$root" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$repro_build" \
    EMBEDDED_OUTPUT_DIR="$repro_export" \
    "$root/Tests/Support/embedded/embedded-swift-reproducible-build.sh" >/dev/null
test -f "$repro_export/swift-reproducible-build.json"
grep -Fq '"reproducible": true' "$repro_export/swift-reproducible-build.json"
grep -Fqx -- "-B $repro_build -D SDKCONFIG=$repro_build/sdkconfig set-target esp32c6" "$log"
grep -Fqx -- "-B $repro_build -D SDKCONFIG=$repro_build/sdkconfig build" "$log"

# A source tree, project root, and broad build root are all rejected before
# the clean helper can invoke rm or idf.py.
repro_idf_calls=$(wc -l < "$log")
if output=$(PATH="$bin_dir:$PATH" FAKE_IDF_LOG="$log" IDF_PATH="$idf_dir" \
    AXOLOTY_SOURCE_DIR="$root" AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    EMBEDDED_PROJECT_DIR="$project_dir" EMBEDDED_BUILD_DIR="$root" \
    EMBEDDED_OUTPUT_DIR="$tmp/rejected-output" \
    "$root/Tests/Support/embedded/embedded-swift-reproducible-build.sh" 2>&1); then
    echo 'Core root unexpectedly accepted as reproducible build directory' >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fq 'cannot be the project or Core tree'
test "$(wc -l < "$log")" -eq "$repro_idf_calls"

echo 'embedded source boundary self-test: OK'
