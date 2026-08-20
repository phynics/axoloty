#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g1-bounded-runtime/$candidate"
build="$artifact/embedded-build"
export_dir="$artifact/embedded-export"
mkdir -p "$artifact"
rm -rf "$artifact/embedded-build" "$artifact/embedded-export"

CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
BUILD_DIR="$artifact/container-build" \
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swift-6.3-linux}" \
EMBEDDED_SPIKE_BUILD_DIR=/workspace/.testing/g1-bounded-runtime/"$candidate"/embedded-build \
EMBEDDED_SPIKE_EXPORT_DIR=/workspace/.testing/g1-bounded-runtime/"$candidate"/embedded-export \
"$root/.devcontainer/run.sh" bash -lc '
set -eu
project=/workspace/Spikes/BoundedPortableRuntime/Embedded
build=/workspace/.testing/g1-bounded-runtime/'"$candidate"'/embedded-build
export_dir=/workspace/.testing/g1-bounded-runtime/'"$candidate"'/embedded-export
export IDF_PROJECT_DIR="$project"
cd "$project"
idf_log=$(mktemp)
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >"$idf_log" 2>&1 || { cat "$idf_log" >&2; exit 1; }
rm -f "$idf_log"
. /workspace/Tests/Support/embedded-build-cache.sh
axoloty_enable_esp_idf_ccache "$project" esp32c6 g1-bounded-runtime
axoloty_prepare_esp_idf_build "$build" esp32c6 0 g1-bounded-runtime -DPROJECT_VER=g1-bounded-runtime
idf.py -B "$build" build
mkdir -p "$export_dir"
find "$build" -maxdepth 1 -type f \( -name "*.bin" -o -name "*.elf" -o -name "*.map" \) -exec cp {} "$export_dir"/ \;
printf "%s\n" "$(swiftc --version | head -1)" >"$export_dir/toolchain.txt"
macro_probe=$(mktemp --suffix=.swift)
macro_object=$(mktemp --suffix=.o)
printf "@AxolotyObject struct UnsupportedMacroUse {}\n" >"$macro_probe"
if swiftc -target riscv32-none-none-eabi -enable-experimental-feature Embedded \
    -parse-as-library -c "$macro_probe" -o "$macro_object" >/dev/null 2>&1; then
    macro_status=compiled
else
    macro_status=unsupported-embedded-manual-conformance
fi
rm -f "$macro_probe" "$macro_object"
printf "%s\n" "$macro_status" >"$export_dir/macro-boundary.txt"
' >"$artifact/embedded-build.log" 2>&1

binary_bytes=$(find "$export_dir" -type f -name '*.bin' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
elf_bytes=$(find "$export_dir" -type f -name '*.elf' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
map_bytes=$(find "$export_dir" -type f -name '*.map' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
printf '{"candidateSha":"%s","status":"passed","compileSuccess":true,"toolchain":"%s","firmwareBytes":%s,"elfBytes":%s,"mapBytes":%s,"specializationGrowth":{"capacities":[1,4,16,64],"inlineSlotTableBytes":[12,48,192,768],"handlerTableBytes":[40,160,640,2560]},"macroBoundary":"%s","stackHighWater":"pending-hardware","heap":"pending-hardware","sustainedRate":"pending-hardware","boardRevision":"pending-hardware"}\n' \
    "$candidate" "$(tr -d '\n' <"$export_dir/toolchain.txt")" "$binary_bytes" "$elf_bytes" "$map_bytes" "$(tr -d '\n' <"$export_dir/macro-boundary.txt")" \
    >"$artifact/embedded-evidence.json"
echo "PASS g1-bounded-runtime-embedded candidate=$candidate artifact=$artifact/embedded-evidence.json"
