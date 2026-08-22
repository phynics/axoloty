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
node - "$probe/check-sanitized.sh" <<'NODE'
const fs = require("node:fs");
const source = fs.readFileSync(process.argv[2], "utf8");
const propagated = /CONTAINER_ENV_VARS=ASAN_OPTIONS\s*\\\n\s*ASAN_OPTIONS="\$\{ASAN_OPTIONS:-detect_leaks=0\}"\s*\\\n\s*run_swift swift test/;
if (!propagated.test(source)) {
  throw new Error("sanitized node does not propagate ASAN_OPTIONS=detect_leaks=0 to both execution branches");
}
NODE
node --check "$validator"
node --check "$embedded_assembler"
jq empty "$schema"
grep -Fq '.package(path: "../../Packages/AxolotyObjectModel")' "$probe/Package.swift"
grep -Fq '.package(path: "../../Packages/AxolotyCoatyModels")' "$probe/Package.swift"
grep -Fq '.package(path: "../../Packages/AxolotyWire")' "$probe/Package.swift"
grep -Fq 'measurementPoints = [1, 16, 64]' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'measurementPolicy = "simultaneous-object-envelope-schema-model-specializations"' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'saturationMeasurement' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'schemaRegistryOperation' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'typedObjectOperation' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'predicateOperation' "$probe/Sources/BoundedObjectModelProbe/main.swift"
grep -Fq 'CoatyFilterAdapter<16, 16, 16, 64>' "$root/Embedded/swift/main/CoatyModelsModuleConsumer.swift"
grep -Fq 'do throws(ProtocolError)' "$root/Embedded/swift/main/CoatyModelsModuleConsumer.swift"
grep -Fq 'let adapter = try CoatyFilterAdapter<16, 16, 16, 64>' "$root/Embedded/swift/main/CoatyModelsModuleConsumer.swift"
if grep -Fq 'let adapter: CoatyFilterAdapter' "$root/Embedded/swift/main/CoatyModelsModuleConsumer.swift"; then
    echo "error: embedded CoatyModels consumer reintroduces an outer noncopyable adapter binding" >&2
    exit 1
fi
grep -Fq 'adapter.matches(object: object)' "$root/Embedded/swift/main/CoatyModelsModuleConsumer.swift"
grep -Fq 'adapter.encode(to: &writer)' "$root/Embedded/swift/main/CoatyModelsModuleConsumer.swift"
grep -Fq 'heaptrack-call-growth' "$assembler"
grep -Fq 'foundation-schema-model-predicate-module-linkage' "$embedded_assembler"

node - "$tmp/probe.json" "$tmp/allocations.tsv" "$tmp/sections.tsv" <<'NODE'
const fs = require("node:fs");
const [probe, allocations, sections] = process.argv.slice(2);
fs.writeFileSync(probe, JSON.stringify({
  schemaVersion: 1,
  evidenceKind: "object-model-probe",
  measurementPoints: [1, 16, 64],
  measurementPolicy: "simultaneous-object-envelope-schema-model-specializations",
  layouts: [1, 16, 64].flatMap(measurementPoint => [
    {measurementPoint, axis: "object", type: "BoundedDynamicObject", size: 1, alignment: 1, stride: 1, byteCapacity: measurementPoint, fieldCapacity: measurementPoint},
    {measurementPoint, axis: "envelope", type: "ObjectEnvelope", size: 1, alignment: 1, stride: 1, nameCapacity: measurementPoint, externalIDCapacity: measurementPoint},
  ]),
  schemaLayouts: [1, 16, 64].map(measurementPoint => ({measurementPoint, axis: "schema-registry", type: "ObjectSchemaRegistry", size: 1, alignment: 1, stride: 1, registryCapacity: measurementPoint})),
  predicateLayouts: [1, 16, 64].map(measurementPoint => ({measurementPoint, axis: "predicate", type: "ObjectPredicate", size: 1, alignment: 1, stride: 1, nodeCapacity: measurementPoint, pathCapacity: measurementPoint, literalCapacity: measurementPoint, arenaCapacity: measurementPoint})),
  operations: [1, 16, 64].map(measurementPoint => ({measurementPoint, byteCapacity: measurementPoint, fieldCapacity: measurementPoint, nameCapacity: measurementPoint, externalIDCapacity: measurementPoint, objectInitialization: measurementPoint === 1 ? "rejected-capacityExceeded" : "accepted", envelopeInitialization: true, randomizedEditRead: measurementPoint > 1, saturationMeasurement: measurementPoint === 1 ? "minimum-object-rejection" : "edit-capacity-failure", saturationRejected: true, unchangedAfterSaturation: true, schemaRegistration: measurementPoint === 1 ? "rejected-capacityExceeded" : "accepted", schemaRegistryCount: measurementPoint === 1 ? 1 : 4, schemaRegistrySaturated: measurementPoint === 1, schemaRegistryUnchangedAfterSaturation: measurementPoint === 1, typedObjectInitialization: measurementPoint === 1 ? "rejected-capacityExceeded" : "accepted", typedObjectValueTypePreserved: measurementPoint > 1, typedObjectByteCapacity: 512, typedObjectFieldCapacity: measurementPoint, predicateInitialization: measurementPoint === 1 ? "rejected-capacityExceeded" : "accepted", predicateDecodeEvaluateEncode: measurementPoint > 1, predicateRoundTrip: measurementPoint > 1})),
}));
fs.writeFileSync(allocations, [1, 16, 64].flatMap(capacity => [
  [capacity, "object-initialization", 3, 4, 7],
  [capacity, "object-warmed", 0, 4, 4],
  [capacity, "envelope-initialization", 2, 5, 7],
  [capacity, "envelope-warmed", 0, 5, 5],
  [capacity, "schema-registry-initialization", 1, 1, 2],
  [capacity, "typed-object-initialization", 1, 1, 2],
  [capacity, "typed-object-warmed", 0, 1, 1],
  [capacity, "predicate-initialization", 1, 1, 2],
  [capacity, "predicate-warmed", 0, 1, 1],
]).map(row => row.join("\t")).join("\n") + "\n");
fs.writeFileSync(sections, ".text\t123\n");
NODE
node "$assembler" "$tmp/probe.json" "$tmp/allocations.tsv" "$tmp/sections.tsv" \
    0123456 1.5 123 "Swift version 6.3 (swift-6.3-RELEASE)" "$tmp/assembled.json"
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
write("missing-predicate-layout", report => { delete report.predicateLayouts; });
write("duplicate-operation", report => { report.operations[1] = report.operations[0]; });
write("missing-operation", report => { report.operations.pop(); });
write("duplicate-allocation", report => { report.allocations[1] = report.allocations[0]; });
write("missing-allocation", report => { report.allocations.pop(); });
write("missing-sections", report => { delete report.compilation.releaseSections; });
write("wrong-capacity", report => { report.operations[0].measurementPoint = 2; });
write("wrong-toolchain", report => { report.toolchain = "Swift 6.3"; });
write("wrong-object-initialization", report => { report.operations[0].objectInitialization = "accepted"; });
write("wrong-envelope-initialization", report => { report.operations[1].envelopeInitialization = false; });
write("wrong-randomized-edit-read", report => { report.operations[1].randomizedEditRead = false; });
write("wrong-saturation-measurement", report => { report.operations[1].saturationMeasurement = "minimum-object-rejection"; });
write("fake-predicate", report => { report.operations[1].predicateDecodeEvaluateEncode = false; });
write("fake-canonical", report => { report.operations[1].predicateRoundTrip = false; });
write("wrong-schema-rejection", report => { report.operations[0].schemaRegistration = "rejected-invalidSchema"; });
write("wrong-typed-rejection", report => { report.operations[0].typedObjectInitialization = "rejected-invalidField"; });
write("wrong-predicate-rejection", report => { report.operations[0].predicateInitialization = "rejected-invalidPredicate"; });
write("fake-registry", report => { report.operations[1].schemaRegistryCount = 1; });
write("nonzero-warmed", report => { report.allocations[1].objectWarmed = 1; });
NODE
for invalid in duplicate-layout missing-layout missing-predicate-layout duplicate-operation missing-operation duplicate-allocation missing-allocation missing-sections wrong-capacity wrong-toolchain wrong-object-initialization wrong-envelope-initialization wrong-randomized-edit-read wrong-saturation-measurement fake-predicate fake-canonical wrong-schema-rejection wrong-typed-rejection wrong-predicate-rejection fake-registry nonzero-warmed; do
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
  coverage: "foundation-schema-model-predicate",
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
if (report.evidenceKind !== "embedded-cross-build" || report.coverage !== "foundation-schema-model-predicate-module-linkage") process.exit(1);
NODE

echo "G3 object-model evidence harness checks passed"
