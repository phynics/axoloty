#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
probe="$root/Spikes/BoundedObjectModelEvidence"
schema="$probe/Evidence/evidence.schema.json"
validator="$probe/Evidence/validate-evidence.mjs"
assembler="$probe/Evidence/assemble-host-evidence.mjs"
embedded_assembler="$probe/Evidence/assemble-embedded-evidence.mjs"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test -x "$probe/check-host.sh"
test -x "$probe/check-sanitized.sh"
test -x "$assembler"
test -x "$probe/check-embedded.sh"
test -f "$embedded_assembler"
sh -n "$probe/check-host.sh" "$probe/check-sanitized.sh" \
    "$probe/check-embedded.sh" \
    "$root/Spikes/BoundedPortableRuntime/measure-allocations.sh"
node --check "$validator"
node --check "$embedded_assembler"
jq empty "$schema"
grep -Fq '.package(path: "../../Packages/AxolotyObjectModel")' "$probe/Package.swift"
grep -Fq '.package(path: "../../Packages/AxolotyWire")' "$probe/Package.swift"
grep -Fq 'measurementPoints = [1, 16, 64]' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'measurementPolicy = "simultaneous-object-and-envelope-specializations"' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'saturationMeasurement' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'heaptrack-call-growth' "$assembler"
grep -Fq 'foundation-module-linkage-only' "$embedded_assembler"

node - "$tmp/probe.json" "$tmp/allocations.tsv" "$tmp/sections.tsv" <<'NODE'
const fs = require("node:fs");
const [probe, allocations, sections] = process.argv.slice(2);
fs.writeFileSync(probe, JSON.stringify({
  schemaVersion: 1,
  evidenceKind: "object-model-probe",
  measurementPoints: [1, 16, 64],
  measurementPolicy: "simultaneous-object-and-envelope-specializations",
  layouts: [1, 16, 64].flatMap(measurementPoint => [
    {measurementPoint, axis: "object", type: "BoundedDynamicObject", size: 1, alignment: 1, stride: 1, byteCapacity: measurementPoint, fieldCapacity: measurementPoint},
    {measurementPoint, axis: "envelope", type: "ObjectEnvelope", size: 1, alignment: 1, stride: 1, nameCapacity: measurementPoint, externalIDCapacity: measurementPoint},
  ]),
  operations: [1, 16, 64].map(measurementPoint => ({measurementPoint, byteCapacity: measurementPoint, fieldCapacity: measurementPoint, nameCapacity: measurementPoint, externalIDCapacity: measurementPoint, objectInitialization: "accepted", envelopeInitialization: true, randomizedEditRead: true, saturationMeasurement: "edit-capacity-failure", saturationRejected: true, unchangedAfterSaturation: true})),
}));
fs.writeFileSync(allocations, [1, 16, 64].flatMap(capacity => [
  [capacity, "object-initialization", 3, 4, 7],
  [capacity, "object-warmed", 0, 4, 4],
  [capacity, "envelope-initialization", 2, 5, 7],
  [capacity, "envelope-warmed", 0, 5, 5],
]).map(row => row.join("\t")).join("\n") + "\n");
fs.writeFileSync(sections, ".text\t123\n");
NODE
node "$assembler" "$tmp/probe.json" "$tmp/allocations.tsv" "$tmp/sections.tsv" \
    0123456 1.5 123 "Swift 6.3" "$tmp/assembled.json"
node - "$tmp/assembled.json" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (report.allocations[0].objectInitialization !== 3) process.exit(1);
if (report.allocations[0].envelopeInitialization !== 2) process.exit(1);
if (report.allocations[0].byteCapacity !== 1 || report.allocations[0].nameCapacity !== 1) process.exit(1);
NODE
node "$validator" "$schema" "$tmp/assembled.json" >/dev/null
node - "$tmp/assembled.json" "$tmp" <<'NODE'
const fs = require("node:fs");
const source = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const directory = process.argv[3];
const write = (name, mutate) => {
  const value = structuredClone(source);
  mutate(value);
  fs.writeFileSync(`${directory}/${name}.json`, JSON.stringify(value));
};
write("duplicate-layout", report => { report.layouts[1] = report.layouts[0]; });
write("missing-layout", report => { report.layouts.pop(); });
write("duplicate-operation", report => { report.operations[1] = report.operations[0]; });
write("missing-operation", report => { report.operations.pop(); });
write("duplicate-allocation", report => { report.allocations[1] = report.allocations[0]; });
write("missing-allocation", report => { report.allocations.pop(); });
write("missing-sections", report => { delete report.compilation.releaseSections; });
write("wrong-capacity", report => { report.operations[0].measurementPoint = 2; });
NODE
for invalid in duplicate-layout missing-layout duplicate-operation missing-operation duplicate-allocation missing-allocation missing-sections wrong-capacity; do
    if node "$validator" "$schema" "$tmp/$invalid.json" >/dev/null 2>&1; then
        echo "error: validator accepted $invalid evidence" >&2
        exit 1
    fi
done

node - "$tmp/sanitized.json" <<'NODE'
const fs = require("node:fs");
const output = process.argv[2];
fs.writeFileSync(output, JSON.stringify({
  schemaVersion: 1,
  evidenceKind: "sanitized",
  candidateSha: "0123456",
  status: "passed",
  sanitizer: "address",
  measurementPoints: [1, 16, 64],
  hardware: "pending-hardware",
}));
NODE
node "$validator" "$schema" "$tmp/sanitized.json" >/dev/null

printf '%s\n' \
    'compileSuccess	true' \
    'compileSeconds	12.5' \
    'toolchain	Swift version 6.3 (swift-6.3-RELEASE)' \
    'firmwareBytes	100' \
    'elfBytes	200' \
    'mapBytes	300' >"$tmp/embedded-metadata.tsv"
printf '.text\t64\n.data\t4\n' >"$tmp/embedded-sections.tsv"
node "$embedded_assembler" "$tmp/embedded-metadata.tsv" "$tmp/embedded-sections.tsv" 0123456 "$tmp/embedded.json"
node "$validator" "$schema" "$tmp/embedded.json" >/dev/null
node - "$tmp/embedded.json" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (report.evidenceKind !== "embedded-cross-build" || report.coverage !== "foundation-module-linkage-only") process.exit(1);
NODE

echo "G3 object-model evidence harness checks passed"
