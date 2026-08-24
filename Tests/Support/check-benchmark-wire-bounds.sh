#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Wire bounds benchmark for issue #301.
#
# Runs the WireBoundsTests (truncation, corruption, malformed input, nesting,
# size limits, router capacity, parser work bounds) in the container, verifying that
# every malformed input is rejected with a structured error — no trap, OOB
# access, timeout, or unbounded allocation. Release timing and size-class
# comparisons live in `make benchmark-wire`, not in ordinary Swift tests.

set -eu

fail() {
    echo "BENCHMARK WIRE BOUNDS FAIL: $1" >&2
    exit 1
}

echo "== Running wire bounds tests (release mode) =="
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}" \
IMAGE="${IMAGE:-axoloty-dev}" \
BUILD_DIR="${BUILD_DIR:-/tmp/coaty-swift-build/axoloty/swift-6.3-linux/debug}" \
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
.devcontainer/run.sh swift test $(test -n "${SWIFT_LOCKED_ARGS:-}" && echo "$SWIFT_LOCKED_ARGS") \
    --filter "WireBounds|TruncationBounds|CorruptionBounds|MalformedInput|NestingDepth|SizeLimit|RouterCapacity|ParserWorkBounds" \
    2>&1 || fail "bounds tests failed"

echo "BENCHMARK WIRE BOUNDS OK"
