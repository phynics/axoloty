#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build this firmware checkout against a Core preparation report. The script
# owns the ESP-IDF invocation; Core preparation remains in validate.sh.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
build_dir=${EMBEDDED_BUILD_DIR:-"/workspace/.build/external-firmware/$proof_run_id"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$build_dir/evidence"}
manifest="$evidence_dir/consumer-preparation.json"
clean_room="$evidence_dir/clean-room.json"
sdkconfig="$build_dir/sdkconfig"

mkdir -p "$build_dir" "$evidence_dir"
"$script_dir/validate.sh" "$manifest"
manifest=$(realpath -e -- "$manifest")
export AXOLOTY_CONSUMER_MANIFEST="$manifest"

idf_path=${IDF_PATH:-/opt/esp/idf}
if [ ! -f "$idf_path/export.sh" ]; then
    echo "error: ESP-IDF export script is unavailable: $idf_path/export.sh" >&2
    exit 69
fi
# shellcheck source=/dev/null
. "$idf_path/export.sh" >/dev/null 2>&1

cd "$project_dir"
if [ ! -f "$build_dir/CMakeCache.txt" ] || \
    ! grep -q '^IDF_TARGET:STRING=esp32c6$' "$build_dir/CMakeCache.txt"; then
    idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" set-target esp32c6
fi

echo "== build external firmware =="
echo "project: $project_dir"
echo "Core manifest: $manifest"
echo "parallelism: ${CMAKE_BUILD_PARALLEL_LEVEL:-default}"
set +e
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build > "$evidence_dir/build.log" 2>&1
build_status=$?
set -e
cat "$evidence_dir/build.log"
if [ "$build_status" -ne 0 ]; then
    echo "error: ESP-IDF build failed; see $evidence_dir/build.log" >&2
    exit "$build_status"
fi

artifact="$build_dir/axoloty-swift.bin"
if [ ! -f "$artifact" ]; then
    echo "error: ESP-IDF did not produce $artifact" >&2
    exit 1
fi

node "$script_dir/write-provenance.mjs" \
    "$manifest" "$artifact" "$evidence_dir/provenance.json" \
    "$project_dir" "$build_dir" "$clean_room"
echo "External firmware build passed"
echo "  artifact: $artifact"
echo "  provenance: $evidence_dir/provenance.json"
