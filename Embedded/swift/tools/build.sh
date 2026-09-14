#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build this firmware checkout against a Core preparation report. The script
# owns the ESP-IDF invocation; Core preparation remains in validate.sh.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
proof_root=${EMBEDDED_PROOF_ROOT:-/workspace/.build}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
preparation_scratch=${EMBEDDED_PREPARATION_SCRATCH:-"$proof_root/core-tools"}
manifest="$evidence_dir/preparation.json"
clean_room="$evidence_dir/clean-room.json"
sdkconfig="$build_dir/sdkconfig"

mkdir -p "$build_dir" "$evidence_dir" "$preparation_scratch" "$proof_root/tooling"
if [ -z "${AXOLOTY_PROOF_RUN_ID:-}" ] ||
    ! printf '%s' "$AXOLOTY_PROOF_RUN_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; then
    echo "error: AXOLOTY_PROOF_RUN_ID must be a stable filesystem-safe identifier" >&2
    exit 64
fi
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

: > "$evidence_dir/build.log"
cd "$project_dir"
if [ ! -f "$build_dir/CMakeCache.txt" ] || \
    ! grep -q '^IDF_TARGET:STRING=esp32c6$' "$build_dir/CMakeCache.txt"; then
    idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" set-target esp32c6 >> "$evidence_dir/build.log" 2>&1
fi

echo "== build external firmware =="
echo "project: $project_dir"
echo "Core manifest: $manifest"
echo "parallelism: ${CMAKE_BUILD_PARALLEL_LEVEL:-default}"
set +e
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build >> "$evidence_dir/build.log" 2>&1
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

cp "$artifact" "$evidence_dir/axoloty-swift.bin"

node "$script_dir/write-provenance.mjs" \
    "$manifest" "$artifact" "$evidence_dir/build-provenance.json" \
    "$project_dir" "$build_dir" "$clean_room"
echo "External firmware build passed"
echo "  artifact: $artifact"
echo "  provenance: $evidence_dir/build-provenance.json"
