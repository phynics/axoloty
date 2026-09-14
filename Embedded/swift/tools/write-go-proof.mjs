// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";

const [provenancePath, smokePath, chipInfoPath, outputPath] = process.argv.slice(2);
if (![provenancePath, smokePath, chipInfoPath, outputPath].every(Boolean)) {
  console.error("usage: write-go-proof.mjs provenance smoke-result chip-info output");
  process.exit(64);
}
const provenance = JSON.parse(fs.readFileSync(provenancePath, "utf8"));
const smoke = JSON.parse(fs.readFileSync(smokePath, "utf8"));
if (provenance.status !== "passed" || smoke.validation?.passed !== true) {
  throw new Error("cannot write a GO proof from failed provenance or smoke evidence");
}
const chipInfo = fs.readFileSync(chipInfoPath, "utf8");
if (!/ESP32-C6/i.test(chipInfo)) throw new Error("chip evidence does not identify ESP32-C6");
const output = {
  schemaVersion: 1,
  status: "passed",
  decision: "GO",
  proof: provenance.proof,
  proofRunId: provenance.proofRunId,
  core: provenance.core,
  firmware: provenance.firmware,
  artifact: provenance.artifact,
  preparationManifest: provenance.preparationManifest,
  cleanRoomEvidence: provenance.cleanRoomEvidence,
  chipEvidence: chipInfoPath,
  smokeEvidence: smokePath,
  smoke: {
    runId: smoke.runId,
    device: smoke.device,
    validation: smoke.validation,
    linesCaptured: smoke.linesCaptured,
  },
  checks: {
    ...provenance.checks,
    chip: "ESP32-C6",
    smokeProtocol: "embedded-swift-smoke-v2",
    artifactFlashed: true,
  },
};
const temporary = `${outputPath}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(temporary, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, outputPath);
