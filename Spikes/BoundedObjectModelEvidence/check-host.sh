#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedObjectModelEvidence"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g3-object-model/$candidate"
build="$artifact/host-build"
mkdir -p "$artifact"

run_swift() {
    if [ "${AXOLOTY_DEVCONTAINER:-0}" = 1 ]; then
        "$@"
        return
    fi
    CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} \
    IMAGE=${IMAGE:-axoloty-dev} \
    BUILD_DIR="$build" \
    SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
    "$root/.devcontainer/run.sh" "$@"
}

run_swift swift test -Xswiftc -warnings-as-errors \
    --package-path /workspace/Spikes/BoundedObjectModelEvidence \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    >"$artifact/tests.log" 2>&1
run_swift swift run --quiet \
    --package-path /workspace/Spikes/BoundedObjectModelEvidence \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    bounded-object-model-probe >"$artifact/probe.json" 2>"$artifact/probe.log"

start_ns=$(date +%s%N)
run_swift swift build -Xswiftc -warnings-as-errors \
    --configuration release --product bounded-object-model-probe \
    --package-path /workspace/Spikes/BoundedObjectModelEvidence \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    >"$artifact/release-build.log" 2>&1
end_ns=$(date +%s%N)
compile_seconds=$(awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.3f", (end-start)/1000000000 }')

run_swift bash /workspace/Spikes/BoundedPortableRuntime/measure-allocations.sh \
    /workspace/Spikes/BoundedObjectModelEvidence \
    /workspace/.testing/g3-object-model/"$candidate"/allocation-measurements.tsv \
    "1 16 64" \
    "object-initialization object-warmed envelope-initialization envelope-warmed" \
    bounded-object-model-probe 1 1000 \
    >"$artifact/allocation-measurements.log" 2>&1

release_binary=$(find "$probe/.build" -type f -path '*/release/bounded-object-model-probe' -perm -111 -print -quit)
[ -n "$release_binary" ] || { echo "release probe binary not found" >&2; exit 1; }
release_bytes=$(stat -c '%s' "$release_binary")
size -A "$release_binary" | awk '$2 ~ /^[0-9]+$/ { print $1 "\t" $2 }' >"$artifact/release-sections.tsv"

CANDIDATE_SHA="$candidate" PROBE_JSON="$artifact/probe.json" \
COMPILE_SECONDS="$compile_seconds" RELEASE_BYTES="$release_bytes" \
ALLOCATIONS="$artifact/allocation-measurements.tsv" SECTIONS="$artifact/release-sections.tsv" \
ARTIFACT="$artifact/host-evidence.json" node <<'NODE'
const fs = require("fs");

const report = JSON.parse(fs.readFileSync(process.env.PROBE_JSON, "utf8"));
const allocationRows = fs.readFileSync(process.env.ALLOCATIONS, "utf8").trim().split(/\n/).filter(Boolean).map(line => {
  const [capacity, measurementCase, growth, smallCount, largeCount] = line.split("\t").map(Number);
  return {capacity, measurementCase, growth, smallCount, largeCount};
});
const allocations = [1, 16, 64].map(capacity => {
  const value = measurementCase => allocationRows.find(row => row.capacity === capacity && row.measurementCase === measurementCase);
  return {
    capacity,
    measurement: "heaptrack-call-growth",
    objectInitialization: value("object-initialization").growth,
    objectWarmed: value("object-warmed").growth,
    envelopeInitialization: value("envelope-initialization").growth,
    envelopeWarmed: value("envelope-warmed").growth,
  };
});
const sections = fs.readFileSync(process.env.SECTIONS, "utf8").trim().split(/\n/).filter(Boolean).map(line => {
  const [name, bytes] = line.split("\t");
  return {name, bytes: Number(bytes)};
});
const evidence = {
  ...report,
  schemaVersion: 1,
  evidenceKind: "host",
  candidateSha: process.env.CANDIDATE_SHA,
  toolchain: "Swift 6.3",
  compilation: {
    debugTests: "passed",
    sanitizedTests: "separate-node",
    compileSeconds: Number(process.env.COMPILE_SECONDS),
    releaseBinaryBytes: Number(process.env.RELEASE_BYTES),
    releaseSections: sections,
  },
  allocations,
  hardware: "pending-hardware",
};
fs.writeFileSync(process.env.ARTIFACT, JSON.stringify(evidence, null, 2) + "\n");
NODE

node "$probe/Evidence/validate-evidence.mjs" \
    "$probe/Evidence/evidence.schema.json" "$artifact/host-evidence.json"
echo "PASS g3-object-model-evidence-host candidate=$candidate artifact=$artifact/host-evidence.json"
