// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [provenancePath, smokePath, deviceManifestPath, outputPath, artifactPath] = process.argv.slice(2);
if (![provenancePath, smokePath, deviceManifestPath, outputPath, artifactPath].every(Boolean)) {
  console.error("usage: write-go-proof.mjs build-provenance smoke-result device-manifest output artifact");
  process.exit(64);
}
const provenance = JSON.parse(fs.readFileSync(provenancePath, "utf8"));
const smoke = JSON.parse(fs.readFileSync(smokePath, "utf8"));
const device = JSON.parse(fs.readFileSync(deviceManifestPath, "utf8"));
const artifact = fs.realpathSync(artifactPath);
const artifactHash = crypto.createHash("sha256").update(fs.readFileSync(artifact)).digest("hex");
if (provenance.status !== "passed" || smoke.validation?.passed !== true ||
    device.chip !== "esp32c6" || device.queried !== true) {
  throw new Error("cannot write a GO proof from failed provenance or smoke evidence");
}
if (provenance.core?.sha !== provenance.firmware?.extractedRevision ||
    provenance.artifact?.path !== artifact || provenance.artifact?.sha256 !== artifactHash ||
    provenance.firmwareSha256 !== artifactHash ||
    smoke.runId !== "embedded-swift-smoke-v2") {
  throw new Error("proof evidence has mismatched Core, firmware, artifact bytes, or smoke identities");
}
const output = {
  schemaVersion: 1,
  result: "passed",
  proof: provenance.proof,
  proofRunId: provenance.proofRunId,
  core: provenance.core,
  firmware: provenance.firmware,
  artifact: provenance.artifact,
  preparationManifest: provenance.preparationManifest,
  cleanRoomEvidence: provenance.cleanRoomEvidence,
  deviceManifest: deviceManifestPath,
  smokeEvidence: smokePath,
  coreSha: provenance.core.sha,
  contractSHA256: provenance.core.contractSHA256,
  firmwareSha256: artifactHash,
  device: device.chip,
  smoke: {
    runId: smoke.runId,
    device: smoke.device,
    validation: smoke.validation,
    linesCaptured: smoke.linesCaptured,
  },
  checks: {
    ...provenance.checks,
    chip: device.chip,
    smokeProtocol: "embedded-swift-smoke-v2",
    artifactFlashed: true,
  },
};
const temporary = `${outputPath}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(temporary, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, outputPath);
