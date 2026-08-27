#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
validator="$root/Tests/Support/validate-g6-resource-evidence.mjs"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repository="$tmp/repository"
fixture="$tmp/evidence"
mkdir -p "$repository" "$fixture/artifacts"
printf '%s\n' 'resource evidence' > "$fixture/artifacts/run.log"
printf '%s\n' '0.5.1' > "$repository/VERSION"
(cd "$repository" && git init -q && git config user.email test@example.invalid && git config user.name test && git add . && git commit -qm fixture)
commit=$(git -C "$repository" rev-parse HEAD)
tree=$(git -C "$repository" rev-parse HEAD^{tree})
version=$(tr -d '[:space:]' < "$repository/VERSION")
digest=$(sha256sum "$fixture/artifacts/run.log" | awk '{print $1}')
cat > "$fixture/evidence.json" <<EOF
{
  "schemaVersion": 1,
  "gate": "g6-resource-evidence",
  "subject": {"repository":"github.com/phynics/axoloty","commit":"$commit","tree":"$tree","version":"$version","clean":true},
  "approval": {"status":"approved","policyDigest":"policy-1"},
  "environments": {
    "host": {"runs":[{"runID":"host-1","sourceCommit":"$commit","compiler":"Swift 6.3","optimization":"release","policyDigest":"policy-1","board":"linux-host","container":"axoloty-build@sha256:host","corpusDigest":"corpus-host","sourceSetDigest":"sources-host","measurements":{"binaryBytes":1},"artifacts":[{"path":"artifacts/run.log","byteCount":18,"sha256":"$digest"}]},{"runID":"host-2","sourceCommit":"$commit","compiler":"Swift 6.3","optimization":"release","policyDigest":"policy-1","board":"linux-host","container":"axoloty-build@sha256:host","corpusDigest":"corpus-host","sourceSetDigest":"sources-host","measurements":{"binaryBytes":1},"artifacts":[{"path":"artifacts/run.log","byteCount":18,"sha256":"$digest"}]}]},
    "esp32c6": {"implementation":"embedded-swift","powerCycleRuns":2,"sustainedWorkload":{"durationSeconds":600,"messageRatePerSecond":100,"measuredCapacityPerSecond":125},"runs":[{"runID":"device-1","sourceCommit":"$commit","compiler":"Embedded Swift","optimization":"release","policyDigest":"policy-1","board":"esp32c6","container":"esp-idf@sha256:device","corpusDigest":"corpus-device","sourceSetDigest":"sources-device","measurements":{"freeHeap":1},"artifacts":[{"path":"artifacts/run.log","byteCount":18,"sha256":"$digest"}]},{"runID":"device-2","sourceCommit":"$commit","compiler":"Embedded Swift","optimization":"release","policyDigest":"policy-1","board":"esp32c6","container":"esp-idf@sha256:device","corpusDigest":"corpus-device","sourceSetDigest":"sources-device","measurements":{"freeHeap":1},"artifacts":[{"path":"artifacts/run.log","byteCount":18,"sha256":"$digest"}]}]}
  }
}
EOF
(cd "$root" && node "$validator" "$fixture/evidence.json" "$fixture" "$repository") >/dev/null
sed -i 's/"implementation":"embedded-swift"/"implementation":"c-surrogate"/' "$fixture/evidence.json"
if (cd "$root" && node "$validator" "$fixture/evidence.json" "$fixture" "$repository") >/dev/null 2>&1; then
    echo "error: resource validator accepted C surrogate evidence" >&2
    exit 1
fi
echo "G6 resource evidence negative self-test passed"
