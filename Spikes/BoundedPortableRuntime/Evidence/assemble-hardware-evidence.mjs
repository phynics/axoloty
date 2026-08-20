// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [root, artifact, candidateSha] = process.argv.slice(2);
if (!root || !artifact || !candidateSha) {
  console.error("usage: assemble-hardware-evidence.mjs ROOT ARTIFACT CANDIDATE_SHA");
  process.exit(2);
}

const budgetPath = path.join(root, "Benchmarks/Baselines/budget-manifest.json");
const budgetSource = fs.readFileSync(budgetPath);
const budgetManifest = JSON.parse(budgetSource);
const embedded = JSON.parse(fs.readFileSync(path.join(artifact, "embedded-evidence.json")));
const median = values => {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
const relativeMAD = values => {
  const center = median(values);
  return center === 0 ? 0 : median(values.map(value => Math.abs(value - center))) / center;
};
const configurations = [1, 4, 16, 64].map(capacity => {
  const crossBuild = embedded.configurations.find(value => value.capacity === capacity);
  const runs = [1, 2].map(runNumber => JSON.parse(fs.readFileSync(
    path.join(artifact, "hardware-runs", `capacity-${capacity}-run-${runNumber}.json`),
    "utf8",
  )));
  return {
    capacity,
    crossBuild,
    runs: runs.map((run, index) => ({
      ...run,
      runNumber: index + 1,
      relativeMAD: relativeMAD(run.rateSamplesPerSecond),
    })),
  };
});
const first = configurations[0].runs[0];
const noiseLimit = budgetManifest.noisePolicy.relativeMAD;
const passed = configurations.every(configuration => configuration.runs.every(run =>
  run.initializationAllocations === 0 &&
  run.steadyStateAllocations === 0 &&
  run.initializationHeapBefore === run.initializationHeapAfter &&
  run.steadyStateHeapBefore === run.steadyStateHeapAfter &&
  run.mainStackHighWater >= 4_000 &&
  run.sustainedRatePerSecond >= 125 &&
  run.relativeMAD <= noiseLimit &&
  configuration.crossBuild.firmwareBytes <= 1_048_576
));
const report = {
  schemaVersion: 1,
  evidenceKind: "hardware",
  candidateSha,
  status: passed ? "passed" : "failed",
  board: {target: "esp32c6", revision: String(first.boardRevision), flashBytes: first.flashBytes},
  budget: {
    manifestSha256: crypto.createHash("sha256").update(budgetSource).digest("hex"),
    relativeMAD: noiseLimit,
    allocationRule: budgetManifest.noisePolicy.allocationVariance,
    stackReserveBytes: 4_000,
  },
  configurations,
};
fs.writeFileSync(path.join(artifact, "hardware-evidence.json"), `${JSON.stringify(report, null, 2)}\n`);
