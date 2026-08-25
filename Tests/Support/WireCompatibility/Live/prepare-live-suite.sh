#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Prepare immutable live-suite inputs before any timeout-bound scenario starts.
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
runtime() { "$RUNTIME" "$@"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
REFERENCE_DIR="$ROOT_DIR/Tests/Support/WireCompatibility/ReferenceAgents/coatyjs"
DEV_IMAGE="${DEV_IMAGE:-localhost/axoloty-dev:latest}"
JS_IMAGE="${JS_IMAGE:-localhost/coatyswift-wire-coatyjs:2.4.0}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/axoloty-wire-module-cache

mkdir -p "$BUILD_DIR" "$SPM_CACHE_DIR"
if ! runtime image inspect "$DEV_IMAGE" >/dev/null 2>&1; then
    echo "Missing prepared development image: $DEV_IMAGE" >&2
    echo "Run the live suite through 'make test-wire-live'." >&2
    exit 1
fi

runtime build -t "$JS_IMAGE" "$REFERENCE_DIR"
runtime run --rm \
    -v "$ROOT_DIR:/workspace" \
    -v "$BUILD_DIR:/swift-build" \
    -v "$SPM_CACHE_DIR:/swiftpm-cache" \
    -w /workspace \
    -e "SWIFTPM_MODULECACHE_OVERRIDE=$SWIFTPM_MODULECACHE_OVERRIDE" \
    "$DEV_IMAGE" swift build \
    --build-tests \
    --scratch-path /swift-build \
    --cache-path /swiftpm-cache \
    --disable-automatic-resolution \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -module-cache-path \
    -Xswiftc "$SWIFTPM_MODULECACHE_OVERRIDE"
