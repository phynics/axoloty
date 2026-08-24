#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Proves that warmed macro dispatch and fixed owning-action operations do not
# add heap allocations as their iteration count grows.

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
package_dir="$root_dir/Packages/AxolotyStaticRuntime"
small_iters=${1:-1}
large_iters=${2:-200}
binary="$package_dir/.build/x86_64-unknown-linux-gnu/release/StaticIoOwnershipAllocation"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/axoloty-static-io-alloc.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() {
    echo "STATIC IO OWNERSHIP ALLOCATION FAIL: $1" >&2
    exit 1
}

command -v heaptrack >/dev/null 2>&1 || fail "heaptrack not found"
command -v heaptrack_print >/dev/null 2>&1 || fail "heaptrack_print not found"

swift build --package-path "$package_dir" -c release \
    --product StaticIoOwnershipAllocation \
    --cache-path "${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
    --disable-automatic-resolution >/dev/null

count_allocations() {
    heaptrack_print "$1.gz" 2>/dev/null \
        | grep -m1 "calls to allocation functions" \
        | grep -oE '^[0-9]+' \
        || echo 0
}

for operation in handler sink; do
    small="$scratch/$operation-small"
    large="$scratch/$operation-large"
    "$binary" "$operation" "$large_iters" >/dev/null 2>&1 \
        || fail "$operation smoke run failed"
    heaptrack -o "$small" "$binary" "$operation" "$small_iters" >/dev/null 2>&1 \
        || fail "$operation small profile failed"
    heaptrack -o "$large" "$binary" "$operation" "$large_iters" >/dev/null 2>&1 \
        || fail "$operation large profile failed"
    small_count=$(count_allocations "$small")
    large_count=$(count_allocations "$large")
    [ "$small_count" -eq "$large_count" ] \
        || fail "$operation allocations grew: $small_count -> $large_count"
    echo "$operation allocation calls: $small_count -> $large_count (growth 0)"
done

echo "STATIC IO OWNERSHIP ALLOCATION OK"
