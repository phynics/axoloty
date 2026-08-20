#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedPortableRuntime"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g1-bounded-runtime/$candidate"
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
    --package-path /workspace/Spikes/BoundedPortableRuntime \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    >"$artifact/host-tests.log" 2>&1
run_swift swift test -Xswiftc -warnings-as-errors \
    --package-path /workspace/Spikes/BoundedPortableRuntime/MacroProbe \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    >"$artifact/macro-host-tests.log" 2>&1
run_swift swift run --quiet --package-path /workspace/Spikes/BoundedPortableRuntime \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    bounded-runtime-probe >"$artifact/probe.log" 2>&1
time_file="$artifact/release-seconds.txt"
start_ns=$(date +%s%N)
run_swift swift build -Xswiftc -warnings-as-errors \
    --configuration release --product bounded-runtime-probe \
    --package-path /workspace/Spikes/BoundedPortableRuntime \
    --cache-path /workspace/.swiftpm-cache --disable-automatic-resolution \
    >"$artifact/release-build.log" 2>&1
end_ns=$(date +%s%N)
awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.3f\n", (end-start)/1000000000 }' >"$time_file"

probe_json=$(node -e '
const fs=require("fs");
const lines=fs.readFileSync(process.argv[1],"utf8").trim().split(/\n/).reverse();
const line=lines.find(value=>value.trim().startsWith("{"));
if (!line) process.exit(2);
process.stdout.write(line.trim());
' "$artifact/probe.log")
release_binary=$(find "$probe/.build" -type f -path '*/release/bounded-runtime-probe' -print -quit)
release_bytes=0
if [ -n "$release_binary" ]; then
    release_bytes=$(stat -c '%s' "$release_binary")
fi
compile_seconds=$(cat "$time_file")

PROBE_JSON="$probe_json" CANDIDATE_SHA="$candidate" COMPILE_SECONDS="$compile_seconds" \
RELEASE_BYTES="$release_bytes" ARTIFACT="$artifact/host-evidence.json" \
node <<'NODE'
const fs = require('fs');
const report = JSON.parse(process.env.PROBE_JSON);
report.candidateSha = process.env.CANDIDATE_SHA;
report.compilation = {
  debugTests: 'passed',
  sanitizedTests: 'pending',
  macroHost: 'passed',
  embedded: 'pending-hardware',
  compileSeconds: Number(process.env.COMPILE_SECONDS),
  releaseBinaryBytes: Number(process.env.RELEASE_BYTES),
  releaseSectionBytes: Number(process.env.RELEASE_BYTES),
};
fs.writeFileSync(process.env.ARTIFACT, JSON.stringify(report, null, 2) + '\n');
NODE

echo "PASS g1-bounded-runtime-host candidate=$candidate artifact=$artifact/host-evidence.json"
