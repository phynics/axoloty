#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g1-bounded-runtime/$candidate"
build="$artifact/sanitized-build"
mkdir -p "$artifact"
run_swift() {
    if [ "${AXOLOTY_DEVCONTAINER:-0}" = 1 ]; then
        "$@"
        return
    fi
    CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
    BUILD_DIR="$build" SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swift-6.3-linux}" \
    CONTAINER_ENV_VARS=ASAN_OPTIONS ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}" \
    "$root/.devcontainer/run.sh" "$@"
}
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
BUILD_DIR="$build" SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
CONTAINER_ENV_VARS=ASAN_OPTIONS \
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}" \
run_swift swift test -Xswiftc -warnings-as-errors -Xswiftc -sanitize=address \
    --package-path /workspace/Spikes/BoundedPortableRuntime \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    --filter BoundedPortableRuntimeTests >"$artifact/sanitized-tests.log" 2>&1
printf '{"candidateSha":"%s","status":"passed","sanitizer":"address","hardware":"pending-hardware"}\n' \
    "$candidate" >"$artifact/sanitized-evidence.json"
echo "PASS g1-bounded-runtime-sanitized candidate=$candidate artifact=$artifact/sanitized-evidence.json"
