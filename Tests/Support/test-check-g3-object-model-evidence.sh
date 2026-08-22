#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
probe="$root/Spikes/BoundedObjectModelEvidence"
schema="$probe/Evidence/evidence.schema.json"
validator="$probe/Evidence/validate-evidence.mjs"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test -x "$probe/check-host.sh"
test -x "$probe/check-sanitized.sh"
sh -n "$probe/check-host.sh" "$probe/check-sanitized.sh" \
    "$root/Spikes/BoundedPortableRuntime/measure-allocations.sh"
node --check "$validator"
jq empty "$schema"
grep -Fq '.package(path: "../../Packages/AxolotyObjectModel")' "$probe/Package.swift"
grep -Fq '.package(path: "../../Packages/AxolotyWire")' "$probe/Package.swift"
grep -Fq 'measurementCapacities = [1, 16, 64]' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'capacityPolicy = "measurement-points-only"' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'saturationMeasurement' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'heaptrack-call-growth' "$probe/check-host.sh"

node - "$tmp/sanitized.json" <<'NODE'
const fs = require("node:fs");
const output = process.argv[2];
fs.writeFileSync(output, JSON.stringify({
  schemaVersion: 1,
  evidenceKind: "sanitized",
  candidateSha: "0123456",
  status: "passed",
  sanitizer: "address",
  measurementCapacities: [1, 16, 64],
  hardware: "pending-hardware",
}));
NODE
node "$validator" "$schema" "$tmp/sanitized.json" >/dev/null

echo "G3 object-model evidence harness checks passed"
