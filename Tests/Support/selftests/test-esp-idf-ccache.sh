#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Container-only proof that the production ccache environment reuses a CMake
# compiler result across two project/worktree directories.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null
compiler=riscv32-esp-elf-gcc
for tool in ccache cmake "$compiler"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "required ccache fixture tool is unavailable: $tool" >&2
        exit 1
    fi
done

. "$root/Tests/Support/embedded/embedded-build-cache.sh"
export AXOLOTY_ESP_IDF_CCACHE_DIR="$tmp/cache"

for fixture in a b; do
    fixture_dir="$tmp/fixture-$fixture"
    mkdir -p "$fixture_dir"
    cat > "$fixture_dir/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(AxolotyCcacheFixture C)
add_library(axoloty_ccache_fixture STATIC fixture.c)
CMAKE
    cat > "$fixture_dir/fixture.c" <<'C'
int axoloty_ccache_fixture(void) { return 42; }
C
done

CCACHE_DIR="$AXOLOTY_ESP_IDF_CCACHE_DIR" ccache --zero-stats >/dev/null
for fixture in a b; do
    fixture_dir="$tmp/fixture-$fixture"
    axoloty_enable_esp_idf_ccache "$fixture_dir" esp32c6 compiler-launcher-fixture
    cmake -S "$fixture_dir" -B "$fixture_dir/build" \
        -DCMAKE_C_COMPILER="$compiler" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY >/dev/null
    cmake --build "$fixture_dir/build" >/dev/null
done

hits=$(CCACHE_DIR="$AXOLOTY_ESP_IDF_CCACHE_DIR" ccache --print-stats | \
    awk '$1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { hits += $2 } END { print hits + 0 }')
misses=$(CCACHE_DIR="$AXOLOTY_ESP_IDF_CCACHE_DIR" ccache --print-stats | \
    awk '$1 == "cache_miss" { print $2 + 0 }')
test "$hits" -ge 1
test "$misses" -eq 1

echo 'ESP-IDF ccache cross-worktree self-test: OK'
