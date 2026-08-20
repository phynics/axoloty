// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const directory = path.dirname(new URL(import.meta.url).pathname);
const validator = path.join(directory, "validate-evidence.mjs");
const schema = path.join(directory, "evidence.schema.json");

function withEvidence(value, body) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "g1-evidence-"));
  const evidence = path.join(scratch, "evidence.json");
  fs.writeFileSync(evidence, JSON.stringify(value));
  try { body(evidence); } finally { fs.rmSync(scratch, {recursive: true}); }
}

test("accepts a schema-conforming report", () => withEvidence({
  schemaVersion: 1,
  evidenceKind: "sanitized",
  candidateSha: "0123456",
  status: "passed",
  sanitizer: "address",
  hardware: "pending-hardware",
}, evidence => {
  assert.doesNotThrow(() => execFileSync(process.execPath, [validator, schema, evidence]));
}));

test("rejects drift and additional fields", () => withEvidence({
  schemaVersion: 1,
  evidenceKind: "sanitized",
  candidateSha: "not-a-sha",
  status: "passed",
  sanitizer: "address",
  hardware: "pending-hardware",
  invented: true,
}, evidence => {
  assert.throws(() => execFileSync(process.execPath, [validator, schema, evidence]));
}));
