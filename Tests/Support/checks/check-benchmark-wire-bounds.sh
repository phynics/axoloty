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

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
wire_reader="$root/Packages/AxolotyWire/Sources/AxolotyWire/WireReader.swift"

for forbidden_path in \
    'preflight(' \
    'scanString(' \
    'scanNumber(' \
    'literal(' \
    'hex4('
do
    if grep -Fq "$forbidden_path" "$wire_reader"; then
        fail "found unbounded tokenizer workspace: $forbidden_path"
    fi
done

grep -Fq 'guard buffer.count <= WireBufferConfig.maxPayloadSize else' "$wire_reader" \
    || fail "payload bound must precede tokenizer workspace allocation"
grep -Fq 'capacity: buffer.count + 8' "$wire_reader" \
    || fail "input-sized bounded tokenizer workspace is missing"
[ "$(grep -Fo 'JSONTokenizer(bytes:' "$wire_reader" | wc -l)" -eq 1 ] \
    || fail "WireReader must construct one tokenizer"
grep -Fq '.scanValueResult()' "$wire_reader" \
    || fail "WireReader must perform one tokenizer scan"
tokenizer_result="$root/Packages/AxolotyWire/Sources/AxolotyWire/JSONTokenizerResult.swift"
grep -Fq 'try scanValue()' "$tokenizer_result" \
    || fail "shared tokenizer result must perform one tokenizer scan"

if [ "${AXOLOTY_WIRE_BOUNDS_SOURCE_ONLY:-0}" = 1 ]; then
    echo "WIRE READER SOURCE BOUNDS OK"
    exit 0
fi

echo "== Running wire bounds tests (release mode) =="
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}" \
IMAGE="${IMAGE:-axoloty-dev}" \
BUILD_DIR="${BUILD_DIR:-/tmp/coaty-swift-build/axoloty/swift-6.3-linux/debug}" \
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
.devcontainer/run.sh swift test $(test -n "${SWIFT_LOCKED_ARGS:-}" && echo "$SWIFT_LOCKED_ARGS") \
    --filter "WireBounds|TruncationBounds|CorruptionBounds|MalformedInput|NestingDepth|SizeLimit|RouterCapacity|ParserWorkBounds" \
    2>&1 || fail "bounds tests failed"

echo "BENCHMARK WIRE BOUNDS OK"
