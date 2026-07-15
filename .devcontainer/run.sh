#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${CONTAINER_RUNTIME:-}
image=${IMAGE:-coatyswift-dev}
workdir=${WORKDIR:-/workspace}
build_dir=${BUILD_DIR:-"$root_dir/.build"}
spm_cache_dir=${SPM_CACHE_DIR:-"${HOME}/.cache/coaty-swift/swiftpm/swift-6.3-linux"}
build_lock=${BUILD_LOCK:-1}
lock_dir="${build_dir}.lock"

mkdir -p "$build_dir"
if [ "$build_lock" = "1" ]; then
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 1
    done

    cleanup() {
        rmdir "$lock_dir" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM
elif [ "$build_lock" != "0" ]; then
    echo "BUILD_LOCK must be 0 or 1, got: $build_lock" >&2
    exit 2
fi

if [ "${AXOLOTY_DEVCONTAINER:-0}" = "1" ]; then
    "$@"
    exit $?
fi

if [ -z "$runtime" ]; then
    echo "No podman or docker runtime found" >&2
    exit 1
fi

mkdir -p "$spm_cache_dir"
"$runtime" run --rm \
    -v "$root_dir:$workdir" \
    -v "$build_dir:$workdir/.build" \
    -v "$spm_cache_dir:$workdir/.swiftpm-cache" \
    -w "$workdir" \
    "$image" "$@"
