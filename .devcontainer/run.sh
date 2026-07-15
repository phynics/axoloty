#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

if [ "${AXOLOTY_DEVCONTAINER:-0}" = "1" ]; then
    exec "$@"
fi

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${CONTAINER_RUNTIME:-}
image=${IMAGE:-coatyswift-dev}
workdir=${WORKDIR:-/workspace}
build_dir=${BUILD_DIR:-"$root_dir/.build"}
spm_cache_dir=${SPM_CACHE_DIR:-"${HOME}/.cache/coaty-swift/swiftpm/swift-6.3-linux"}

if [ -z "$runtime" ]; then
    echo "No podman or docker runtime found" >&2
    exit 1
fi

mkdir -p "$build_dir" "$spm_cache_dir"
exec "$runtime" run --rm \
    -v "$root_dir:$workdir" \
    -v "$build_dir:$workdir/.build" \
    -v "$spm_cache_dir:$workdir/.swiftpm-cache" \
    -w "$workdir" \
    "$image" "$@"
