#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Shared Embedded Swift Core/tool preparation. Callers provide the firmware
# build directory; all resolved dependency and macro paths remain in that
# caller-owned storage.

set -eu

embedded_core_prepare_tools() {
    build_dir=$1
    resolver=$2
    AXOLOTY_EMBEDDED_CORE_NO_EXEC=1 . "$resolver"
    embedded_core_resolve

    case "$build_dir" in
        /*) ;;
        *) echo "error: Embedded Swift build directory must be absolute: $build_dir" >&2; return 1 ;;
    esac
    build_dir_canonical=$(realpath -m -- "$build_dir")
    macro_scratch=${AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR:-$build_dir.core-tools}
    case "$macro_scratch" in
        /*) ;;
        *) echo "error: AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR must be absolute: $macro_scratch" >&2; return 1 ;;
    esac
    macro_scratch_canonical=$(realpath -m -- "$macro_scratch")
    case "$macro_scratch_canonical" in
        "$build_dir_canonical"|"$build_dir_canonical"/*)
            echo "error: macro scratch must be outside the ESP-IDF build directory: $macro_scratch" >&2
            return 1
            ;;
    esac
    mkdir -p "$macro_scratch"
    macro_scratch=$(realpath -e -- "$macro_scratch")
    case "$macro_scratch" in
        "$build_dir_canonical"|"$build_dir_canonical"/*)
            echo "error: macro scratch resolves inside the ESP-IDF build directory: $macro_scratch" >&2
            return 1
            ;;
    esac

    macro_lock_fd=9
    macro_lock_held=0
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$macro_scratch/.axoloty-macro.lock"
        if ! flock -w "${AXOLOTY_MACRO_LOCK_TIMEOUT_SECONDS:-1800}" "$macro_lock_fd"; then
            echo "error: timed out waiting for macro scratch lock: $macro_scratch/.axoloty-macro.lock" >&2
            exec 9>&-
            return 1
        fi
        macro_lock_held=1
    fi
    release_macro_lock() {
        if [ "$macro_lock_held" = 1 ]; then
            flock -u "$macro_lock_fd" || true
            exec 9>&-
            macro_lock_held=0
        fi
    }
    fail_tool_preparation() {
        message=$1
        release_macro_lock
        echo "error: $message" >&2
        return 1
    }

    if [ -n "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL:-}" ]; then
        macro_tool=$(realpath -e -- "$AXOLOTY_STATIC_RUNTIME_MACRO_TOOL" 2>/dev/null) || {
            fail_tool_preparation "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL does not exist: $AXOLOTY_STATIC_RUNTIME_MACRO_TOOL"
        }
    else
        command -v swift >/dev/null 2>&1 || fail_tool_preparation \
            "swift is required to build AxolotyStaticRuntimeMacrosImplementation"
        if ! swift build \
            --package-path "$AXOLOTY_SOURCE_DIR/Packages/AxolotyStaticRuntime" \
            --scratch-path "$macro_scratch" \
            --disable-automatic-resolution \
            --configuration debug \
            --target AxolotyStaticRuntime; then
            fail_tool_preparation "failed to build AxolotyStaticRuntime and its macro executable"
        fi
        if ! macro_bin_path=$(swift build \
            --package-path "$AXOLOTY_SOURCE_DIR/Packages/AxolotyStaticRuntime" \
            --scratch-path "$macro_scratch" \
            --disable-automatic-resolution \
            --configuration debug \
            --show-bin-path); then
            fail_tool_preparation "could not locate AxolotyStaticRuntime macro output directory"
        fi
        macro_tool="$macro_bin_path/AxolotyStaticRuntimeMacrosImplementation-tool"
    fi
    macro_tool=$(realpath -e -- "$macro_tool" 2>/dev/null) || {
        fail_tool_preparation "AxolotyStaticRuntime macro executable is missing: $macro_tool"
    }
    case "$macro_tool" in
        "$macro_scratch"/*) ;;
        *) fail_tool_preparation "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL must be inside its scratch directory: $macro_tool" ;;
    esac

    if [ -n "${AXOLOTY_JSON_CORE_SOURCE_DIR:-}" ]; then
        json_core_dir=$(realpath -e -- "$AXOLOTY_JSON_CORE_SOURCE_DIR" 2>/dev/null) || {
            fail_tool_preparation "AXOLOTY_JSON_CORE_SOURCE_DIR does not exist: $AXOLOTY_JSON_CORE_SOURCE_DIR"
        }
    else
        json_core_dir=$(realpath -e -- \
            "$macro_scratch/checkouts/swift-json/Sources/_JSONCore" 2>/dev/null) || {
            fail_tool_preparation "resolved swift-json _JSONCore source is missing under macro scratch: $macro_scratch"
        }
    fi
    case "$json_core_dir" in
        "$macro_scratch"/*) ;;
        *) fail_tool_preparation "AXOLOTY_JSON_CORE_SOURCE_DIR must be inside macro scratch: $json_core_dir" ;
    esac

    AXOLOTY_JSON_CORE_SOURCE_DIR="$json_core_dir"
    AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch"
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool"
    export AXOLOTY_JSON_CORE_SOURCE_DIR AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR AXOLOTY_STATIC_RUNTIME_MACRO_TOOL
    release_macro_lock
}

if [ "${AXOLOTY_EMBEDDED_CORE_TOOLS_NO_EXEC:-0}" != 1 ]; then
    embedded_core_prepare_tools "${1:-/workspace/.build/embedded-swift}" \
        "${2:-/workspace/Tests/Support/embedded/embedded-core-source.sh}"
fi
