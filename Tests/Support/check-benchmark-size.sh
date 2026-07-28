#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
case "${1:-}" in
  --parse) node "$root/Tests/Support/benchmark-size.mjs" parse "$2" "$root"; exit $?;;
  --compare)
    node "$root/Tests/Support/benchmark-size.mjs" compare "$2" "$3"; exit $?;;
  -h|--help) printf '%s\n' 'check-benchmark-size.sh [output-dir]' 'check-benchmark-size.sh --parse <raw-dir>' 'check-benchmark-size.sh --compare <new.json> <baseline.json>'; exit 0;;
esac
output_dir=${1:-$root/.testing/benchmarks/$(cd "$root" && git rev-parse --short HEAD 2>/dev/null || echo unknown)}
mkdir -p "$output_dir"; cd "$root"
swift build -c release --product AxolotyWireConsumer --cache-path .swiftpm-cache --disable-automatic-resolution
swift build -c release --product AxolotyConsumer --cache-path .swiftpm-cache --disable-automatic-resolution
raw_dir=$(mktemp -d); trap 'rm -rf "$raw_dir"' EXIT
size_tool=""; for candidate in llvm-size /usr/local/swift/usr/bin/llvm-size size; do command -v "$candidate" >/dev/null 2>&1 && { size_tool=$candidate; break; }; done
[ -n "$size_tool" ] || { echo "error: no size tool found (tried llvm-size, size)" >&2; exit 1; }
measure() { bin=$1; name=$2; wc -c < "$bin" > "$raw_dir/wc-unstripped-$name.txt"; stripped=$(mktemp); cp "$bin" "$stripped"; strip "$stripped" 2>/dev/null || true; wc -c < "$stripped" > "$raw_dir/wc-stripped-$name.txt"; rm -f "$stripped"; "$size_tool" -A "$bin" > "$raw_dir/llvm-size-$name.txt" 2>&1 || true; readelf -d "$bin" > "$raw_dir/readelf-d-$name.txt" 2>&1 || true; sha256sum "$bin" | cut -d' ' -f1 > "$raw_dir/sha256-$name.txt"; }
measure "$root/.build/release/AxolotyWireConsumer" AxolotyWireConsumer
measure "$root/.build/release/AxolotyConsumer" AxolotyConsumer
swift --version > "$raw_dir/swift-version.txt" 2>&1
swift package show-dependencies --format flatlist > "$raw_dir/deps-flatlist.txt" 2>&1 || true
cp "$root/Package.swift" "$raw_dir/package-swift.txt"
current="$output_dir/size-baseline.json"; sh "$0" --parse "$raw_dir" > "$current"
mkdir -p "$output_dir/raw"; cp -R "$raw_dir/"* "$output_dir/raw/" 2>/dev/null || true
sh "$0" --compare "$current" "$root/Benchmarks/Baselines/size-baseline.json"
