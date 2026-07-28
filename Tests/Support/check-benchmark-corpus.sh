#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates the AxolotyWire benchmark corpus (issue #298).
#
# Loads the corpus manifest and verifies that every payload file exists,
# matches its recorded SHA-256 and byte count, respects the wire buffer
# limits (topic <= 128 bytes, payload <= 512 bytes), and that all 13 wire
# families are covered at each of the three size classes (small, typical,
# maximum = 39 cases). Reference and generated provenance are checked too.
#
# Usage: check-benchmark-corpus.sh [corpus-dir]
#   corpus-dir defaults to Benchmarks/Corpus (relative to the working dir).

set -eu

corpus=${1:-Benchmarks/Corpus}

# Resolve to an absolute path so payload lookups work regardless of CWD.
corpus_abs=$(CDPATH= cd -- "$corpus" && pwd)

node - "$corpus_abs" <<'JS'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const corpus = process.argv[2];
const manifestPath = path.join(corpus, "manifest.json");
if (!fs.existsSync(manifestPath)) { console.error(`error: missing manifest: ${manifestPath}`); process.exit(1); }
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const cases = manifest.cases;
if (!Array.isArray(cases)) { console.error("error: manifest 'cases' is not a list"); process.exit(1); }
const expectedFamilies = new Set(["ADV", "ASC", "CHN", "CLL", "CPL", "DAD", "DSC", "IOV", "QRY", "RSV", "RTN", "RTV", "UPD"]);
const expectedSizes = ["small", "typical", "maximum"];
const errors = [];
const families = new Set(cases.map(item => item.family));
const sizes = new Set(cases.map(item => item.sizeClass));
const combinations = new Set(cases.map(item => `${item.family}:${item.sizeClass}`));
if (cases.length !== 39) errors.push(`expected 39 cases, found ${cases.length}`);
const missingFamilies = [...expectedFamilies].filter(item => !families.has(item)).sort();
const extraFamilies = [...families].filter(item => !expectedFamilies.has(item)).sort();
const missingSizes = expectedSizes.filter(item => !sizes.has(item));
if (missingFamilies.length) errors.push(`missing families: ${JSON.stringify(missingFamilies)}`);
if (extraFamilies.length) errors.push(`unexpected families: ${JSON.stringify(extraFamilies)}`);
if (missingSizes.length) errors.push(`missing size classes: ${JSON.stringify(missingSizes)}`);
for (const family of [...expectedFamilies].sort()) for (const size of expectedSizes) {
  if (!combinations.has(`${family}:${size}`)) errors.push(`missing case for family ${family} size ${size}`);
}
for (const item of cases) {
  const id = item.id ?? "<no id>";
  if (!item.payloadFile) { errors.push(`${id}: missing payloadFile`); continue; }
  const payloadPath = path.join(corpus, item.payloadFile);
  if (!fs.existsSync(payloadPath)) { errors.push(`${id}: payload file not found: ${item.payloadFile}`); continue; }
  const payload = fs.readFileSync(payloadPath);
  if (payload.length > 512) errors.push(`${id}: payload ${payload.length} bytes exceeds 512`);
  const digest = crypto.createHash("sha256").update(payload).digest("hex");
  if (item.payloadSha256 === undefined) errors.push(`${id}: missing payloadSha256`);
  else if (item.payloadSha256 !== digest) errors.push(`${id}: SHA-256 mismatch (expected ${item.payloadSha256}, got ${digest})`);
  if (item.payloadBytes === undefined) errors.push(`${id}: missing payloadBytes`);
  else if (item.payloadBytes !== payload.length) errors.push(`${id}: byte count mismatch (expected ${item.payloadBytes}, got ${payload.length})`);
  const topicLength = Buffer.byteLength(item.topic ?? "", "utf8");
  if (topicLength > 128) errors.push(`${id}: topic ${topicLength} bytes exceeds 128: ${item.topic ?? ""}`);
  const source = item.source ?? {};
  if (source.type === "reference" && !source.provenance) errors.push(`${id}: reference source missing provenance`);
  else if (source.type === "generated" && !("seed" in source)) errors.push(`${id}: generated source missing seed`);
  else if (!["reference", "generated"].includes(source.type)) errors.push(`${id}: invalid source type ${JSON.stringify(source.type)}`);
}
if (errors.length) { for (const error of errors) console.error(`error: ${error}`); process.exit(1); }
console.log(`BENCHMARK CORPUS OK (${cases.length} cases verified)`);
JS
