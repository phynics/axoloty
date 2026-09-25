#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedObjectModelEvidence"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g3-object-model/$candidate"
build="$artifact/host-build"
evidence_name=${AXOLOTY_G3_EVIDENCE_NAME:-host-evidence.json}
node_name=${AXOLOTY_G3_EVIDENCE_NODE:-g3-object-model-evidence-host}
mkdir -p "$artifact"

run_swift() {
    if [ "${AXOLOTY_DEVCONTAINER:-0}" = 1 ]; then
        "$@"
        return
    fi
    CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} \
    IMAGE=${IMAGE:-axoloty-dev} \
    BUILD_DIR="$build" \
    SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.4-linux}" \
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
toolchain=$(run_swift swift --version | head -1)

run_swift bash /workspace/Spikes/BoundedPortableRuntime/measure-allocations.sh \
    /workspace/Spikes/BoundedObjectModelEvidence \
    /workspace/.testing/g3-object-model/"$candidate"/allocation-measurements.tsv \
    "1 16 64" \
    "object-initialization object-warmed envelope-initialization envelope-warmed schema-registry-initialization typed-object-initialization typed-object-warmed predicate-initialization predicate-warmed" \
    bounded-object-model-probe 1 1000 \
    >"$artifact/allocation-measurements.log" 2>&1

release_bin_dir=$(run_swift swift build --configuration release \
    --package-path /workspace/Spikes/BoundedObjectModelEvidence \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution --show-bin-path)
release_binary="$release_bin_dir/bounded-object-model-probe"
[ -n "$release_binary" ] || { echo "release probe binary not found" >&2; exit 1; }
[ -x "$release_binary" ] || { echo "release probe binary not executable: $release_binary" >&2; exit 1; }
release_bytes=$(stat -c '%s' "$release_binary")
size -A "$release_binary" | awk '$2 ~ /^[0-9]+$/ { print $1 "\t" $2 }' >"$artifact/release-sections.tsv"

node "$probe/Evidence/assemble-host-evidence.mjs" \
    "$artifact/probe.json" "$artifact/allocation-measurements.tsv" "$artifact/release-sections.tsv" \
    "$candidate" "$compile_seconds" "$release_bytes" "$toolchain" "$artifact/$evidence_name"

node "$probe/Evidence/validate-evidence.mjs" \
    "$probe/Evidence/evidence.schema.json" "$artifact/$evidence_name"
echo "PASS $node_name candidate=$candidate artifact=$artifact/$evidence_name"
