#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedPortableRuntime"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g1-bounded-runtime/$candidate"
mkdir -p "$artifact"
rm -rf "$artifact/embedded-build" "$artifact/embedded-macro-build" "$artifact/embedded-export"

CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
BUILD_DIR="$artifact/container-build" \
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
"$root/.devcontainer/run.sh" bash -lc '
set -euo pipefail
project=/workspace/Spikes/BoundedPortableRuntime/Embedded
artifact=/workspace/.testing/g1-bounded-runtime/'"$candidate"'
export_dir="$artifact/embedded-export"
mkdir -p "$export_dir"
export IDF_PROJECT_DIR="$project"
cd "$project"
idf_log=$(mktemp)
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >"$idf_log" 2>&1 || { cat "$idf_log" >&2; exit 1; }
rm -f "$idf_log"
. /workspace/Tests/Support/embedded-build-cache.sh

swift build -Xswiftc -warnings-as-errors \
    --package-path /workspace/Spikes/BoundedPortableRuntime/MacroProbe \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    --target BoundedPortableRuntimeMacros \
    >"$artifact/macro-host-plugin-build.log" 2>&1
macro_plugin=$(find /workspace/Spikes/BoundedPortableRuntime/MacroProbe/.build \
    -type f -name BoundedPortableRuntimeMacros-tool -perm -111 -print -quit)
[ -n "$macro_plugin" ] || { echo "macro plugin executable was not built" >&2; exit 1; }
macro_build="$artifact/embedded-macro-build"
axoloty_enable_esp_idf_ccache "$project" esp32c6 g1-bounded-runtime-macro
if idf.py -B "$macro_build" -DPROJECT_VER=g1-bounded-runtime-macro \
    -DG1_CAPACITY=0 -DG1_MACRO_ATTEMPT=ON -DG1_MACRO_PLUGIN="$macro_plugin" \
    reconfigure build \
    >"$artifact/macro-embedded-build.log" 2>&1; then
    macro_status=compiled
else
    macro_status=unsupported-embedded-manual-conformance
fi
printf "%s\n" "$macro_status" >"$export_dir/macro-boundary.txt"
printf "%s\n" "$(swiftc --version | head -1)" >"$export_dir/toolchain.txt"
: >"$export_dir/configurations.tsv"
build="$artifact/embedded-build"
axoloty_enable_esp_idf_ccache "$project" esp32c6 g1-bounded-runtime
axoloty_prepare_esp_idf_build "$build" esp32c6 0 g1-bounded-runtime \
    -DPROJECT_VER=g1-bounded-runtime -DG1_CAPACITY=0

for capacity in 0 1 4 16 64; do
    export_capacity="$export_dir/capacity-$capacity"
    mkdir -p "$export_capacity"
    idf.py -B "$build" -DG1_CAPACITY="$capacity" reconfigure
    start_ns=$(date +%s%N)
    idf.py -B "$build" build
    end_ns=$(date +%s%N)
    compile_seconds=$(awk -v start="$start_ns" -v end="$end_ns" \
        "BEGIN { printf \"%.3f\", (end-start)/1000000000 }")
    find "$build" -maxdepth 1 -type f \( -name "*.bin" -o -name "*.elf" -o -name "*.map" \) \
        -exec cp {} "$export_capacity"/ \;
    firmware=$(find "$build" -maxdepth 1 -type f -name "*.bin" -print -quit)
    elf=$(find "$build" -maxdepth 1 -type f -name "*.elf" -print -quit)
    map=$(find "$build" -maxdepth 1 -type f -name "*.map" -print -quit)
    [ -n "$firmware" ] && [ -n "$elf" ] && [ -n "$map" ]
    read -r text_bytes data_bytes bss_bytes _ < <(riscv32-esp-elf-size "$elf" | tail -1)
    iram_bytes=$(riscv32-esp-elf-size -A "$elf" \
        | awk "\$1 ~ /^\\.iram0\\./ { total += \$2 } END { print total + 0 }")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$capacity" "$compile_seconds" "$(stat -c %s "$firmware")" \
        "$(stat -c %s "$elf")" "$(stat -c %s "$map")" \
        "$text_bytes" "$data_bytes" "$bss_bytes" "$iram_bytes" >>"$export_dir/configurations.tsv"
done
' >"$artifact/embedded-build.log" 2>&1

CANDIDATE_SHA="$candidate" EXPORT_DIR="$artifact/embedded-export" \
ARTIFACT="$artifact/embedded-evidence.json" node <<'NODE'
const fs = require('fs');
const path = require('path');
const rows = fs.readFileSync(path.join(process.env.EXPORT_DIR, 'configurations.tsv'), 'utf8')
  .trim().split(/\n/).map(line => {
    const [capacity, compileSeconds, firmwareBytes, elfBytes, mapBytes, text, data, bss, iram] = line.split('\t').map(Number);
    return {capacity, compileSeconds, firmwareBytes, elfBytes, mapBytes, sections: {text, data, bss, iram}};
  });
const baseline = rows.find(row => row.capacity === 0);
for (const row of rows) {
  row.growth = {
    firmwareBytes: row.firmwareBytes - baseline.firmwareBytes,
    text: row.sections.text - baseline.sections.text,
    data: row.sections.data - baseline.sections.data,
    bss: row.sections.bss - baseline.sections.bss,
    iram: row.sections.iram - baseline.sections.iram,
  };
}
const report = {
  schemaVersion: 1,
  evidenceKind: 'embedded-cross-build',
  candidateSha: process.env.CANDIDATE_SHA,
  status: 'passed',
  compileSuccess: true,
  toolchain: fs.readFileSync(path.join(process.env.EXPORT_DIR, 'toolchain.txt'), 'utf8').trim(),
  macroBoundary: fs.readFileSync(path.join(process.env.EXPORT_DIR, 'macro-boundary.txt'), 'utf8').trim(),
  configurations: rows,
  hardware: 'pending-hardware',
};
fs.writeFileSync(process.env.ARTIFACT, JSON.stringify(report, null, 2) + '\n');
NODE

node "$probe/Evidence/validate-evidence.mjs" \
    "$probe/Evidence/evidence.schema.json" "$artifact/embedded-evidence.json"
echo "PASS g1-bounded-runtime-embedded candidate=$candidate artifact=$artifact/embedded-evidence.json"
