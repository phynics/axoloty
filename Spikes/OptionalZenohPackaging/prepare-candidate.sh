#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
base=0c74f3ae2328a8dc1528088f7b7d3be24f7cf241
candidate="$root/.testing/runs/optional-zenoh-1001/rerun-candidate"
expected="$root/.testing/runs/optional-zenoh-1001"

case "$candidate" in
    "$expected"/*) ;;
    *) echo "error: candidate path escaped private experiment scratch" >&2; exit 2 ;;
esac

mkdir -p "$expected"
rm -rf "$candidate"
mkdir "$candidate"
git -C "$root" archive "$base" | tar -x -C "$candidate"
(cd "$candidate" && git apply "$root/Spikes/OptionalZenohPackaging/root-product.patch")

actual=$(sha256sum "$candidate/Package.swift" | awk '{print $1}')
printf 'base=%s\ncandidate_manifest_sha256=%s\ncandidate=%s\n' "$base" "$actual" "$candidate"
