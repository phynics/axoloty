#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

probe=${1:?probe package path required}
output=${2:?output path required}
capacities=${3:-"1 4 16 64"}
cases=${4:-"inline-initialization inline-warmed handler-initialization handler-warmed"}
binary_name=${5:-bounded-runtime-probe}
small_iterations=${6:-1}
large_iterations=${7:-1000}
binary=$(find "$probe/.build" -type f -path "*/release/$binary_name" -perm -111 -print -quit)
[ -n "$binary" ] || { echo "allocation probe binary not found" >&2; exit 1; }
command -v heaptrack >/dev/null 2>&1 || { echo "heaptrack not found" >&2; exit 1; }
command -v heaptrack_print >/dev/null 2>&1 || { echo "heaptrack_print not found" >&2; exit 1; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/g1-bounded-allocation.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
: >"$output"

allocation_count() {
    heaptrack_print "$1.gz" >"$1.txt" 2>/dev/null
    grep -m1 "calls to allocation functions" "$1.txt" | grep -oE '^[0-9]+'
}

for capacity in $capacities; do
    for allocation_case in $cases; do
        small="$scratch/${capacity}-${allocation_case}-small"
        large="$scratch/${capacity}-${allocation_case}-large"
        heaptrack -o "$small" "$binary" --allocation-case "$allocation_case" \
            --capacity "$capacity" --iterations "$small_iterations" >/dev/null 2>&1
        heaptrack -o "$large" "$binary" --allocation-case "$allocation_case" \
            --capacity "$capacity" --iterations "$large_iterations" >/dev/null 2>&1
        small_count=$(allocation_count "$small")
        large_count=$(allocation_count "$large")
        growth=$((large_count - small_count))
        [ "$growth" -ge 0 ] || growth=0
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$capacity" "$allocation_case" "$growth" "$small_count" "$large_count" >>"$output"
        if [ "$growth" -ne 0 ]; then
            echo "allocation growth for capacity=$capacity case=$allocation_case: $small_count -> $large_count" >&2
            exit 1
        fi
    done
done
