#!/usr/bin/env node
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";

const [metadataPath, sectionsPath, candidateSha, outputPath] = process.argv.slice(2);
if (!metadataPath || !sectionsPath || !candidateSha || !outputPath) {
  console.error("usage: assemble-embedded-evidence.mjs METADATA SECTIONS SHA OUTPUT");
  process.exit(2);
}

const metadata = Object.fromEntries(fs.readFileSync(metadataPath, "utf8").trim().split(/\n/).filter(Boolean).map(line => {
  const separator = line.indexOf("\t");
  if (separator < 1) throw new Error(`invalid metadata line: ${line}`);
  return [line.slice(0, separator), line.slice(separator + 1)];
}));
const number = key => {
  const value = Number(metadata[key]);
  if (!Number.isFinite(value) || value < 0) throw new Error(`invalid numeric metadata ${key}`);
  return value;
};
const sections = fs.readFileSync(sectionsPath, "utf8").trim().split(/\n/).filter(Boolean).map(line => {
  const [name, bytesText] = line.split("\t");
  const bytes = Number(bytesText);
  if (!name || !Number.isInteger(bytes) || bytes < 0) throw new Error(`invalid section line: ${line}`);
  return {name, bytes};
});
if (!sections.some(section => section.name === ".text" || section.name === "text")) {
  throw new Error("embedded report is missing the text section");
}

const report = {
  schemaVersion: 1,
  evidenceKind: "embedded-cross-build",
  candidateSha,
  status: "passed",
  compileSuccess: metadata.compileSuccess === "true",
  coverage: "foundation-schema-model-predicate-module-linkage",
  source: "Embedded/swift",
  toolchain: metadata.toolchain,
  compileSeconds: number("compileSeconds"),
  firmwareBytes: number("firmwareBytes"),
  elfBytes: number("elfBytes"),
  mapBytes: number("mapBytes"),
  sections,
  hardware: "pending-hardware",
};
if (!report.compileSuccess || !report.toolchain) throw new Error("embedded build did not report a successful toolchain build");
fs.writeFileSync(outputPath, JSON.stringify(report, null, 2) + "\n");
