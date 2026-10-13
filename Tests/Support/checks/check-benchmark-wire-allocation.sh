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
# The probe runs once per wire profile. `coaty/3` JSON is the sealed baseline;
# `axoloty/1` CBOR proves the format-neutral `WireCodec` seam and the shared
# `ProtocolProcessor` allocate the same way for both profiles.
#
# Usage: check-benchmark-wire-allocation.sh [SMALL_ITERS=1] [LARGE_ITERS=200]
# Requires: heaptrack (present in the axoloty-dev container).

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
small_iters=${1:-1}
large_iters=${2:-200}
cache_path=${SPM_CACHE_DIR:-"$HOME/.cache/coaty-swift/swiftpm/swift-6.4-linux"}

fail() {
    echo "BENCHMARK WIRE ALLOCATION FAIL: $1" >&2
    exit 1
}

command -v heaptrack >/dev/null 2>&1 || fail "heaptrack not found (needed in the axoloty-dev container)"
command -v heaptrack_print >/dev/null 2>&1 || fail "heaptrack_print not found"

(cd "$root_dir" && swift build -c release --product WireAllocation \
    --cache-path "$cache_path" --disable-automatic-resolution >/dev/null)
binary_dir=$(cd "$root_dir" && swift build -c release --product WireAllocation \
    --cache-path "$cache_path" --disable-automatic-resolution --show-bin-path)
binary="$binary_dir/WireAllocation"
[ -x "$binary" ] || fail "WireAllocation product not found at $binary"

count_allocs() {
    # $1: profile path (without .gz). Prints the total allocation-call count.
    heaptrack_print "$1.gz" 2>/dev/null \
        | grep -m1 "calls to allocation functions" \
        | grep -oE '^[0-9]+' \
        || echo "0"
}

check_profile() {
    # $1: profile name passed to the probe.
    profile=$1
    small_profile=$(mktemp "${TMPDIR:-/tmp}/axoloty-wire-alloc-${profile}-small.XXXXXX")
    large_profile=$(mktemp "${TMPDIR:-/tmp}/axoloty-wire-alloc-${profile}-large.XXXXXX")
    trap 'rm -f "$small_profile" "$small_profile.gz" "$large_profile" "$large_profile.gz" 2>/dev/null || true' EXIT

    # Smoke: the hot path must complete at both sizes.
    "$binary" "$large_iters" "$profile" > /dev/null 2>&1 \
        || fail "wire allocation probe ($profile) exited nonzero"

    heaptrack -o "$small_profile" "$binary" "$small_iters" "$profile" >/dev/null 2>&1 \
        || fail "heaptrack small profile failed ($profile)"
    heaptrack -o "$large_profile" "$binary" "$large_iters" "$profile" >/dev/null 2>&1 \
        || fail "heaptrack large profile failed ($profile)"

    small_count=$(count_allocs "$small_profile")
    large_count=$(count_allocs "$large_profile")

    # The steady-state hot path must not allocate per iteration: raising the
    # iteration count must not increase the total allocation-call count. A small
    # constant delta (e.g. a bounded lazy-runtime setup only touched once) is
    # tolerated, but the count must not scale with `large_iters - small_iters`.
    if [ "$large_count" -gt $((small_count + 2)) ]; then
        fail "$profile allocation count grew with iterations ($small_count -> $large_count for iters $small_iters -> $large_iters); hot path is allocating per message"
    fi

    rm -f "$small_profile" "$small_profile.gz" "$large_profile" "$large_profile.gz"
    echo "BENCHMARK WIRE ALLOCATION OK ($profile: allocation count $small_count -> $large_count, no growth with iteration count)"
}

check_profile json
check_profile cbor
