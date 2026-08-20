// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const directory = path.dirname(new URL(import.meta.url).pathname);
const validator = path.join(directory, "validate-evidence.mjs");
const assembler = path.join(directory, "assemble-hardware-evidence.mjs");
const schema = path.join(directory, "evidence.schema.json");
const repositoryRoot = path.resolve(directory, "../../..");
const budgetManifest = path.resolve(directory, "../../../Benchmarks/Baselines/budget-manifest.json");
const budgetFingerprint = crypto.createHash("sha256").update(fs.readFileSync(budgetManifest)).digest("hex");

function withEvidence(value, body) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "g1-evidence-"));
  const evidence = path.join(scratch, "evidence.json");
  fs.writeFileSync(evidence, JSON.stringify(value));
  try { body(evidence); } finally { fs.rmSync(scratch, {recursive: true}); }
}

function hardwareEvidence() {
  const crossBuild = capacity => ({
    capacity,
    compileSeconds: 1,
    firmwareBytes: 100_000,
    elfBytes: 200_000,
    mapBytes: 50_000,
    sections: {text: 70_000, data: 1_000, bss: 2_000, iram: 10_000},
    growth: {firmwareBytes: 100, text: 100, data: 0, bss: 0, iram: 0},
  });
  const run = (capacity, runNumber) => ({
    schemaVersion: 1,
    evidenceKind: "g1-device-run",
    runNumber,
    capacity,
    initializationAllocations: 0,
    steadyStateAllocations: 0,
    initializationHeapBefore: 100_000,
    initializationHeapAfter: 100_000,
    steadyStateHeapBefore: 100_000,
    steadyStateHeapAfter: 100_000,
    minimumFreeInternalHeap: 90_000,
    largestInternalBlock: 80_000,
    mainStackHighWater: 8_000,
    mainStackSize: 65_536,
    resetReason: 11,
    boardRevision: 0,
    flashBytes: 4_194_304,
    operations: 1_000,
    elapsedMicroseconds: 1_000,
    sustainedRatePerSecond: 1_000,
    rateSamplesPerSecond: [1_000, 1_001],
    inlineLayout: {size: 8, alignment: 4, stride: 8},
    handlerLayout: {size: 24, alignment: 4, stride: 24},
    relativeMAD: 0.001,
  });
  return {
    schemaVersion: 1,
    evidenceKind: "hardware",
    candidateSha: "0123456",
    status: "passed",
    board: {target: "esp32c6", revision: "0", flashBytes: 4_194_304},
    budget: {
      manifestSha256: budgetFingerprint,
      relativeMAD: 0.05,
      allocationRule: "exact-zero",
      stackReserveBytes: 4_000,
    },
    configurations: [1, 4, 16, 64].map(capacity => ({
      capacity,
      crossBuild: crossBuild(capacity),
      runs: [run(capacity, 1), run(capacity, 2)],
    })),
  };
}

function expectRejected(value) {
  withEvidence(value, evidence => {
    assert.throws(
      () => execFileSync(process.execPath, [validator, schema, evidence]),
      error => error?.status === 1,
      "validator must reject evidence with exit status 1",
    );
  });
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
  assert.throws(
    () => execFileSync(process.execPath, [validator, schema, evidence]),
    error => error?.status === 1,
  );
}));

test("accepts complete two-run hardware evidence", () => withEvidence(hardwareEvidence(), evidence => {
  assert.doesNotThrow(() => execFileSync(process.execPath, [validator, schema, evidence]));
}));

test("reassembles retained raw runs without device access", () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "g1-retained-hardware-"));
  const runsDirectory = path.join(scratch, "hardware-runs");
  fs.mkdirSync(runsDirectory);
  const expected = hardwareEvidence();
  fs.writeFileSync(path.join(scratch, "embedded-evidence.json"), JSON.stringify({
    configurations: expected.configurations.map(configuration => configuration.crossBuild),
  }));
  for (const configuration of expected.configurations) {
    for (const run of configuration.runs) {
      const raw = {...run};
      delete raw.runNumber;
      delete raw.relativeMAD;
      fs.writeFileSync(
        path.join(runsDirectory, `capacity-${configuration.capacity}-run-${run.runNumber}.json`),
        JSON.stringify(raw),
      );
    }
  }
  try {
    execFileSync(process.execPath, [assembler, repositoryRoot, scratch, expected.candidateSha]);
    const rebuiltPath = path.join(scratch, "hardware-evidence.json");
    const rebuilt = JSON.parse(fs.readFileSync(rebuiltPath));
    assert.deepEqual(
      rebuilt.configurations.flatMap(configuration => configuration.runs.map(run => run.runNumber)),
      [1, 2, 1, 2, 1, 2, 1, 2],
    );
    assert.doesNotThrow(() => execFileSync(process.execPath, [validator, schema, rebuiltPath]));
  } finally {
    fs.rmSync(scratch, {recursive: true});
  }
});

test("rejects empty hardware configurations and missing runs", () => {
  const empty = hardwareEvidence();
  empty.configurations = [{}, {}, {}, {}];
  expectRejected(empty);

  const oneRun = hardwareEvidence();
  oneRun.configurations[0].runs.pop();
  expectRejected(oneRun);

  const duplicateRun = hardwareEvidence();
  duplicateRun.configurations[0].runs[1].runNumber = 1;
  expectRejected(duplicateRun);
});

test("rejects wrong capacities and missing device measurements", () => {
  const wrongCapacity = hardwareEvidence();
  wrongCapacity.configurations[1].capacity = 1;
  expectRejected(wrongCapacity);

  const missingMeasurement = hardwareEvidence();
  delete missingMeasurement.configurations[0].runs[0].mainStackHighWater;
  expectRejected(missingMeasurement);
});

test("rejects hardware evidence that violates measured budgets", () => {
  const allocation = hardwareEvidence();
  allocation.configurations[0].runs[0].steadyStateAllocations = 1;
  expectRejected(allocation);

  const heapDrift = hardwareEvidence();
  heapDrift.configurations[0].runs[0].steadyStateHeapAfter -= 1;
  expectRejected(heapDrift);

  const stack = hardwareEvidence();
  stack.configurations[0].runs[0].mainStackHighWater = 3_999;
  expectRejected(stack);

  const noise = hardwareEvidence();
  noise.configurations[0].runs[0].relativeMAD = 0.051;
  expectRejected(noise);

  const slow = hardwareEvidence();
  slow.configurations[0].runs[0].sustainedRatePerSecond = 124;
  expectRejected(slow);

  const oversized = hardwareEvidence();
  oversized.configurations[0].crossBuild.firmwareBytes = 1_048_577;
  expectRejected(oversized);

  const wrongBudget = hardwareEvidence();
  wrongBudget.budget.manifestSha256 = "a".repeat(64);
  expectRejected(wrongBudget);
});
