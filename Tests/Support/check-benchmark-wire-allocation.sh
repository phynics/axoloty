#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Host allocation-regression check for the AxolotyWire borrowed decode +
# shared fixed-inline protocol processor hot path (issue #490).
#
# Runs the dedicated WireAllocation probe, which performs ONLY a warmed
# steady-state decode + ProtocolProcessor dispatch pass, under the
# heaptrack malloc profiler. It asserts the documented exact-zero *per-iteration*
# steady-state allocation contract by requiring that the total number of
# allocation calls does not grow as the hot-path iteration count increases.
# One-time startup/construction allocations (DSO registration and host-side
# setup) are constant and bounded; a regression that
# allocates once per decode or dispatch would scale the count with iterations.
#
# Usage: check-benchmark-wire-allocation.sh [SMALL_ITERS=1] [LARGE_ITERS=200]
# Requires: heaptrack (present in the axoloty-dev container).

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
small_iters=${1:-1}
large_iters=${2:-200}
binary="$root_dir/.build/x86_64-unknown-linux-gnu/release/WireAllocation"
small_profile=$(mktemp "${TMPDIR:-/tmp}/axoloty-wire-alloc-small.XXXXXX")
large_profile=$(mktemp "${TMPDIR:-/tmp}/axoloty-wire-alloc-large.XXXXXX")
trap 'rm -f "$small_profile" "$small_profile.gz" "$large_profile" "$large_profile.gz" 2>/dev/null || true' EXIT

fail() {
    echo "BENCHMARK WIRE ALLOCATION FAIL: $1" >&2
    exit 1
}

command -v heaptrack >/dev/null 2>&1 || fail "heaptrack not found (needed in the axoloty-dev container)"
command -v heaptrack_print >/dev/null 2>&1 || fail "heaptrack_print not found"

[ -x "$binary" ] || (cd "$root_dir" && swift build -c release --product WireAllocation \
    --cache-path "${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
    --disable-automatic-resolution >/dev/null)

count_allocs() {
    # $1: profile path (without .gz). Prints the total allocation-call count.
    heaptrack_print "$1.gz" 2>/dev/null \
        | grep -m1 "calls to allocation functions" \
        | grep -oE '^[0-9]+' \
        || echo "0"
}

# Smoke: the hot path must complete at both sizes.
"$binary" "$large_iters" > /dev/null 2>&1 || fail "wire allocation probe exited nonzero"

heaptrack -o "$small_profile" "$binary" "$small_iters" >/dev/null 2>&1 \
    || fail "heaptrack small profile failed"
heaptrack -o "$large_profile" "$binary" "$large_iters" >/dev/null 2>&1 \
    || fail "heaptrack large profile failed"

small_count=$(count_allocs "$small_profile")
large_count=$(count_allocs "$large_profile")

# The steady-state hot path must not allocate per iteration: raising the
# iteration count must not increase the total allocation-call count. A small
# constant delta (e.g. a bounded lazy-runtime setup only touched once) is
# tolerated, but the count must not scale with `large_iters - small_iters`.
if [ "$large_count" -gt $((small_count + 2)) ]; then
    fail "allocation count grew with iterations ($small_count -> $large_count for iters $small_iters -> $large_iters); hot path is allocating per message"
fi

echo "BENCHMARK WIRE ALLOCATION OK (allocation count $small_count -> $large_count, no growth with iteration count)"
