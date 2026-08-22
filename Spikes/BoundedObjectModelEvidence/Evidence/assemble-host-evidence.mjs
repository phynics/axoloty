// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";

const [probePath, allocationsPath, sectionsPath, candidateSha, compileSeconds, releaseBinaryBytes, toolchain, outputPath] = process.argv.slice(2);
if (!probePath || !allocationsPath || !sectionsPath || !candidateSha || !compileSeconds || !releaseBinaryBytes || !toolchain || !outputPath) {
  console.error("usage: assemble-host-evidence.mjs PROBE ALLOCATIONS SECTIONS SHA COMPILE_SECONDS RELEASE_BYTES TOOLCHAIN OUTPUT");
  process.exit(2);
}

const expectedCapacities = [1, 16, 64];
const expectedCases = ["object-initialization", "object-warmed", "envelope-initialization", "envelope-warmed"];

function integer(value, label) {
  if (!/^\d+$/.test(value)) throw new Error(`${label} must be a nonnegative integer`);
  return Number(value);
}

function readAllocations(path) {
  const rows = fs.readFileSync(path, "utf8").trim().split(/\n/).filter(Boolean).map((line, index) => {
    const fields = line.split("\t");
    if (fields.length !== 5) throw new Error(`allocation row ${index + 1} must have five tab-separated fields`);
    const [capacityText, measurementCase, growthText, smallText, largeText] = fields;
    return {
      capacity: integer(capacityText, `allocation row ${index + 1} capacity`),
      measurementCase,
      growth: integer(growthText, `allocation row ${index + 1} growth`),
      smallCount: integer(smallText, `allocation row ${index + 1} small count`),
      largeCount: integer(largeText, `allocation row ${index + 1} large count`),
    };
  });
  const expectedKeys = expectedCapacities.flatMap(capacity => expectedCases.map(measurementCase => `${capacity}:${measurementCase}`));
  const actualKeys = rows.map(row => `${row.capacity}:${row.measurementCase}`);
  if (rows.length !== expectedKeys.length || new Set(actualKeys).size !== actualKeys.length || !expectedKeys.every(key => actualKeys.includes(key))) {
    throw new Error("allocation rows must contain each expected capacity/case exactly once");
  }
  return rows;
}

function readSections(path) {
  return fs.readFileSync(path, "utf8").trim().split(/\n/).filter(Boolean).map((line, index) => {
    const [name, bytesText] = line.split("\t");
    if (!name || bytesText === undefined) throw new Error(`section row ${index + 1} is malformed`);
    return {name, bytes: integer(bytesText, `section row ${index + 1} bytes`)};
  });
}

const report = JSON.parse(fs.readFileSync(probePath, "utf8"));
const rows = readAllocations(allocationsPath);
const allocations = expectedCapacities.map(capacity => {
  const value = measurementCase => rows.find(row => row.capacity === capacity && row.measurementCase === measurementCase);
  return {
    measurementPoint: capacity,
    byteCapacity: capacity,
    fieldCapacity: capacity,
    nameCapacity: capacity,
    externalIDCapacity: capacity,
    measurement: "heaptrack-call-growth",
    objectInitialization: value("object-initialization").growth,
    objectWarmed: value("object-warmed").growth,
    envelopeInitialization: value("envelope-initialization").growth,
    envelopeWarmed: value("envelope-warmed").growth,
  };
});
const evidence = {
  ...report,
  schemaVersion: 1,
  evidenceKind: "host",
  candidateSha,
  toolchain,
  compilation: {
    debugTests: "passed",
    sanitizedTests: "separate-node",
    compileSeconds: Number(compileSeconds),
    releaseBinaryBytes: integer(releaseBinaryBytes, "release binary bytes"),
    releaseSections: readSections(sectionsPath),
  },
  allocations,
  hardware: "pending-hardware",
};
fs.writeFileSync(outputPath, JSON.stringify(evidence, null, 2) + "\n");
