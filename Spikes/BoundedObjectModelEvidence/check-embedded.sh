#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedObjectModelEvidence"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g3-object-model/$candidate"
build="$artifact/embedded-build"
export_dir="$artifact/embedded-export"
mkdir -p "$artifact"

CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
BUILD_DIR="$artifact/container-build" \
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
"$root/.devcontainer/run.sh" bash -lc '
set -euo pipefail
artifact=/workspace/.testing/g3-object-model/'"$candidate"'
build="$artifact/embedded-build"
export_dir="$artifact/embedded-export"
mkdir -p "$export_dir"

# The ESP component compiles the pinned _JSONCore sources from the SwiftPM
# checkout. A clean G3 tier starts without a root package build, so resolve the
# checked-in closure before CMake discovers those sources.
jsoncore_dir=/workspace/.build/checkouts/swift-json/Sources/_JSONCore
if [ ! -d "$jsoncore_dir" ]; then
    /workspace/.devcontainer/resolve.sh
fi
test -d "$jsoncore_dir" || {
    echo "error: pinned swift-json _JSONCore checkout is unavailable at $jsoncore_dir" >&2
    exit 1
}

# The build helper runs in a child process and its sourced ESP-IDF PATH does
# not survive here. Activate the toolchain in this evidence subshell as well
# so post-build section measurement uses the same pinned environment.
idf_log=$(mktemp)
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >"$idf_log" 2>&1 || { cat "$idf_log" >&2; exit 1; }
rm -f "$idf_log"

start_ns=$(date +%s%N)
EMBEDDED_PROJECT_DIR=/workspace/Embedded/swift \
EMBEDDED_BUILD_DIR="$build" \
EMBEDDED_EXPORT_DIR="$export_dir" \
/workspace/Tests/Support/build-embedded-swift.sh >"$artifact/embedded-build.log" 2>&1
end_ns=$(date +%s%N)

firmware="$export_dir/axoloty-swift.bin"
elf="$build/axoloty-swift.elf"
map="$build/axoloty-swift.map"
test -f "$firmware" && test -f "$elf" && test -f "$map"
printf "compileSuccess\\ttrue\\n"
printf "compileSeconds\\t%s\\n" "$(awk -v start="$start_ns" -v end="$end_ns" '"'"'BEGIN { printf "%.3f", (end-start)/1000000000 }'"'"')"
printf "toolchain\\t%s\\n" "$(swift --version | head -1)"
printf "firmwareBytes\\t%s\\n" "$(stat -c %s "$firmware")"
printf "elfBytes\\t%s\\n" "$(stat -c %s "$elf")"
printf "mapBytes\\t%s\\n" "$(stat -c %s "$map")"
riscv32-esp-elf-size -A "$elf" | awk '"'"'NF >= 2 && $1 ~ /^\./ && $2 ~ /^[0-9]+$/ { print $1 "\t" $2 }'"'"' >"$export_dir/sections.tsv"
' >"$artifact/embedded-metadata.tsv" 2>"$artifact/embedded-build.log"

if [ "${AXOLOTY_TIMING_EVIDENCE:-0}" = 1 ]; then
    grep -E '^ccache_(before|after) ' "$artifact/embedded-build.log"
fi

node "$probe/Evidence/assemble-embedded-evidence.mjs" \
    "$artifact/embedded-metadata.tsv" "$artifact/embedded-export/sections.tsv" \
    "$candidate" "$artifact/embedded-evidence.json"
node "$probe/Evidence/validate-evidence.mjs" \
    "$probe/Evidence/evidence.schema.json" "$artifact/embedded-evidence.json"
echo "PASS g3-object-model-evidence-embedded candidate=$candidate artifact=$artifact/embedded-evidence.json"
