#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Shared ESP-IDF incremental-build and compiler-cache policy. Callers source
# this file after activating the pinned ESP-IDF environment.

axoloty_esp_idf_cache_key() {
    target=$1
    flags=$2
    idf_revision=$(git -C "${IDF_PATH:-/opt/esp/idf}" rev-parse HEAD 2>/dev/null || idf.py --version 2>/dev/null || printf unknown)
    compiler_identity=$(riscv32-esp-elf-gcc -dumpmachine -dumpfullversion -dumpversion 2>/dev/null || printf unknown)
    printf '%s\n' "$idf_revision" "$compiler_identity" "$target" "$flags" | sha256sum | awk '{print substr($1, 1, 20)}'
}

axoloty_enable_esp_idf_ccache() {
    project_dir=$1
    target=$2
    flags=$3
    ccache_dir=${AXOLOTY_ESP_IDF_CCACHE_DIR:-}

    if [ -z "$ccache_dir" ] || ! command -v ccache >/dev/null 2>&1; then
        return
    fi

    cache_key=$(axoloty_esp_idf_cache_key "$target" "$flags")
    mkdir -p "$ccache_dir"
    export CCACHE_DIR="$ccache_dir"
    export CCACHE_BASEDIR="$project_dir"
    export CCACHE_NAMESPACE="esp-idf-$cache_key"
    export IDF_CCACHE_ENABLE=1
}

axoloty_prepare_esp_idf_build() {
    build_dir=$1
    target=$2
    clean=$3
    flags=$4
    shift 4

    cache="$build_dir/CMakeCache.txt"
    fingerprint_file="$build_dir/.axoloty-esp-idf-config"
    active_python_root="${IDF_TOOLS_PATH:-${HOME:-/root}/.espressif}/python_env/"
    config_key=$(axoloty_esp_idf_cache_key "$target" "$flags")
    ccache_mode=0
    if [ "${IDF_CCACHE_ENABLE:-0}" = 1 ]; then
        ccache_mode=1
    fi
    expected_fingerprint="$config_key ccache=$ccache_mode"
    requires_reconfigure=0

    case "$clean" in
        0|1) ;;
        *) echo "embedded clean mode must be 0 or 1" >&2; return 2 ;;
    esac

    if [ -f "$cache" ]; then
        if [ "$clean" = 1 ]; then
            requires_reconfigure=1
        elif grep -q 'PYTHON.*python_env' "$cache" && ! grep -Fq "$active_python_root" "$cache"; then
            requires_reconfigure=1
        elif ! grep -q "^IDF_TARGET:STRING=$target$" "$cache"; then
            requires_reconfigure=1
        elif [ ! -f "$fingerprint_file" ] || [ "$(cat "$fingerprint_file")" != "$expected_fingerprint" ]; then
            requires_reconfigure=1
        elif [ "$ccache_mode" = 1 ] && ! grep -Eq '^CCACHE_ENABLE:[^=]+=(1|ON|TRUE)$' "$cache"; then
            requires_reconfigure=1
        fi
    fi

    if [ "$requires_reconfigure" = 1 ]; then
        rm -f "$fingerprint_file"
        idf.py -B "$build_dir" fullclean
    fi

    if [ ! -f "$cache" ]; then
        idf.py -B "$build_dir" "$@" set-target "$target"
        if [ ! -f "$cache" ]; then
            echo "ESP-IDF set-target did not create $cache" >&2
            return 1
        fi
        if [ "$ccache_mode" = 1 ] && ! grep -Eq '^CCACHE_ENABLE:[^=]+=(1|ON|TRUE)$' "$cache"; then
            echo "ESP-IDF configuration did not activate ccache" >&2
            return 1
        fi
        printf '%s\n' "$expected_fingerprint" > "$fingerprint_file"
    fi
}
