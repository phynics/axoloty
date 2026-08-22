#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedObjectModelEvidence"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g3-object-model/$candidate"
build="$artifact/sanitized-build"
mkdir -p "$artifact"

if [ "${AXOLOTY_DEVCONTAINER:-0}" = 1 ]; then
    run_swift() { "$@"; }
else
    run_swift() {
        CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
        BUILD_DIR="$build" \
        SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
        CONTAINER_ENV_VARS=ASAN_OPTIONS ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}" \
        "$root/.devcontainer/run.sh" "$@"
    }
fi

CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
BUILD_DIR="$build" \
SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
CONTAINER_ENV_VARS=ASAN_OPTIONS \
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}" \
run_swift swift test -Xswiftc -warnings-as-errors -Xswiftc -sanitize=address \
    --package-path /workspace/Spikes/BoundedObjectModelEvidence \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    --filter BoundedObjectModelEvidenceTests >"$artifact/sanitized-tests.log" 2>&1
printf '{"schemaVersion":1,"evidenceKind":"sanitized","candidateSha":"%s","status":"passed","sanitizer":"address","measurementPoints":[1,16,64],"coverage":"foundation-schema-model-predicate","hardware":"pending-hardware"}\n' \
    "$candidate" >"$artifact/sanitized-evidence.json"
node "$probe/Evidence/validate-evidence.mjs" \
    "$probe/Evidence/evidence.schema.json" "$artifact/sanitized-evidence.json"
echo "PASS g3-object-model-evidence-sanitized candidate=$candidate artifact=$artifact/sanitized-evidence.json"
