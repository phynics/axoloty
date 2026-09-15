// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createEmbeddedSwiftTestValidator } from "./validate-smoke.mjs";

const [evidenceDirInput, buildDirInput, coreDirInput, firmwareDirInput,
  expectedCoreSha, preparationScratchInput, device, proofRunId] = process.argv.slice(2);
if (![evidenceDirInput, buildDirInput, coreDirInput, firmwareDirInput,
  expectedCoreSha, preparationScratchInput, device, proofRunId].every(Boolean)) {
  console.error("usage: validate-go-proof.mjs evidence-dir build-dir core-dir firmware-dir core-sha preparation-scratch device proof-run-id");
  process.exit(64);
}

const canonical = (value, label) => {
  if (!path.isAbsolute(value)) throw new Error(`${label} must be absolute`);
  try { return fs.realpathSync(value); } catch { throw new Error(`${label} does not exist: ${value}`); }
};
const evidenceDir = canonical(evidenceDirInput, "evidence directory");
const buildDir = canonical(buildDirInput, "build directory");
const coreDir = canonical(coreDirInput, "Core directory");
const firmwareDir = canonical(firmwareDirInput, "firmware directory");
const preparationScratch = canonical(preparationScratchInput, "preparation scratch");
if (!/^[0-9a-f]{40}$/.test(expectedCoreSha)) throw new Error("Core SHA is not a 40-character lowercase revision");
if (device !== "/dev/ttyACM0" && !device.startsWith("/dev/")) throw new Error("device path must be under /dev");

const samePath = (left, right) => canonical(left, "path") === canonical(right, "path");
const under = (root, candidate, label) => {
  const relative = path.relative(root, candidate);
  if (relative.startsWith("..") || path.isAbsolute(relative)) throw new Error(`${label} escapes its declared root`);
};
const required = [
  "build.log", "preparation.json", "build-provenance.json", "device-manifest.json",
  "device-info-raw.txt", "flash.log", "swift-smoke-log.txt", "swift-smoke-result.json",
  "axoloty-swift.bin", "go-proof.json", "clean-room.json", "consumer-preparation.stdout",
];
for (const name of required) {
  const file = path.join(evidenceDir, name);
  if (!fs.statSync(file, { throwIfNoEntry: false } )?.isFile()) throw new Error(`required evidence is missing: ${name}`);
  if (name !== "build.log" && name !== "swift-smoke-log.txt" && fs.statSync(file).size === 0) {
    throw new Error(`required evidence is empty: ${name}`);
  }
}

const readJSON = name => {
  try { return JSON.parse(fs.readFileSync(path.join(evidenceDir, name), "utf8")); }
  catch (error) { throw new Error(`invalid ${name}: ${error.message}`); }
};
const manifest = readJSON("preparation.json");
const cleanRoom = readJSON("clean-room.json");
const provenance = readJSON("build-provenance.json");
const deviceManifest = readJSON("device-manifest.json");
const smoke = readJSON("swift-smoke-result.json");
const proof = readJSON("go-proof.json");
const expect = (condition, message) => { if (!condition) throw new Error(message); };
const sha256 = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const artifact = canonical(path.join(buildDir, "axoloty-swift.bin"), "build artifact");
const durableArtifact = path.join(evidenceDir, "axoloty-swift.bin");
const artifactHash = sha256(artifact);
const artifactBytes = fs.statSync(artifact).size;
expect(sha256(durableArtifact) === artifactHash, "durable binary differs from the build artifact");

expect(manifest.schemaVersion === 1 && manifest.status === "prepared", "preparation report is not prepared schema 1");
expect(manifest.contractSHA256 && /^[0-9a-f]{64}$/.test(manifest.contractSHA256), "preparation contract hash is invalid");
expect(manifest.core?.sourceDir === coreDir && manifest.core.sha === expectedCoreSha && manifest.core.dirty === false,
  "preparation report Core identity is not the selected clean checkout");
const packageNames = ["AxolotyWire", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyCoatyModels", "AxolotyStaticRuntime"];
expect(Array.isArray(manifest.portablePackages) && manifest.portablePackages.length === packageNames.length,
  "preparation report package list is incomplete");
manifest.portablePackages.forEach((entry, index) => {
  expect(entry?.name === packageNames[index], "preparation package order differs from the contract");
  const source = canonical(entry.sourcePath, `${entry.name} source`);
  under(coreDir, source, `${entry.name} source`);
});
expect(manifest.jsonCore?.revision && /^[0-9a-f]{40}$/.test(manifest.jsonCore.revision), "_JSONCore revision is invalid");
const jsonCoreSource = canonical(manifest.jsonCore.sourceDir, "_JSONCore source");
const macroScratch = canonical(manifest.staticRuntimeMacro.scratchDir, "macro scratch");
under(preparationScratch, jsonCoreSource, "_JSONCore source");
under(preparationScratch, canonical(manifest.staticRuntimeMacro.executable, "macro executable"), "macro executable");
expect(macroScratch === preparationScratch && manifest.staticRuntimeMacro.pluginModule === "AxolotyStaticRuntimeMacrosImplementation",
  "macro preparation storage or module is invalid");

expect(cleanRoom.schemaVersion === 1 && cleanRoom.status === "passed" && cleanRoom.proofRunId === proofRunId,
  "clean-room evidence identity is invalid");
expect(cleanRoom.coreRoot === coreDir && cleanRoom.firmwareRoot === firmwareDir &&
  cleanRoom.portableSourceCopied === false && cleanRoom.privateReferenceScan === "passed",
  "clean-room evidence does not prove source isolation");

expect(provenance.schemaVersion === 1 && provenance.status === "passed" &&
  provenance.proof === "real-external-firmware-consumer" && provenance.proofRunId === proofRunId,
  "build provenance identity is invalid");
expect(provenance.core?.sourceDir === coreDir && provenance.core.sha === expectedCoreSha &&
  provenance.core.dirty === false && provenance.core.contractSHA256 === manifest.contractSHA256,
  "build provenance Core identity is invalid");
expect(provenance.firmware?.sourceDir === firmwareDir && provenance.firmware.extractedRevision === expectedCoreSha &&
  provenance.firmware.sourceCopied === false,
  "build provenance firmware identity is invalid");
expect(provenance.artifact?.path === artifact && provenance.artifact.sha256 === artifactHash &&
  provenance.firmwareSha256 === artifactHash && provenance.artifact.byteCount === artifactBytes,
  "build provenance artifact hash or path is invalid");
expect(provenance.preparationManifest === path.join(evidenceDir, "preparation.json") &&
  provenance.cleanRoomEvidence === path.join(evidenceDir, "clean-room.json"),
  "build provenance evidence links are invalid");
expect(provenance.toolchain?.target === "esp32c6" && provenance.checks?.privateReferenceScan === "passed" &&
  provenance.checks?.coreFirmwareRootsDisjoint === true,
  "build provenance toolchain or isolation checks are invalid");

expect(deviceManifest.schemaVersion === 1 && deviceManifest.device === device &&
  deviceManifest.chip === "esp32c6" && deviceManifest.queried === true,
  "device manifest does not prove a queried ESP32-C6");
expect(samePath(deviceManifest.rawInfoPath, path.join(evidenceDir, "device-info-raw.txt")),
  "device manifest raw-info link is invalid");
expect(/ESP32-C6/i.test(fs.readFileSync(path.join(evidenceDir, "device-info-raw.txt"), "utf8")),
  "device-info-raw.txt does not identify ESP32-C6");

const flashLog = fs.readFileSync(path.join(evidenceDir, "flash.log"), "utf8");
expect(/Hash of data verified\./.test(flashLog), "flash.log does not prove an esptool write verification");

const replayValidator = createEmbeddedSwiftTestValidator();
const smokeLog = fs.readFileSync(path.join(evidenceDir, "swift-smoke-log.txt"), "utf8");
for (const rawLine of smokeLog.split(/\r?\n/)) {
  const start = rawLine.indexOf("{");
  const end = rawLine.lastIndexOf("}");
  const line = start >= 0 && end >= start ? rawLine.slice(start, end + 1) : rawLine;
  if (replayValidator.observe(line)) break;
}
const replayedSmoke = replayValidator.result();
expect(replayedSmoke.passed === true,
  `serial smoke log does not replay as passed: ${replayedSmoke.reason ?? "unknown failure"}`);
expect(JSON.stringify(smoke.validation) === JSON.stringify(replayedSmoke),
  "recorded smoke result differs from the independently replayed serial log");

expect(smoke.schemaVersion === 2 && smoke.runId === "embedded-swift-smoke-v2" && smoke.device === device &&
  Number.isInteger(smoke.linesCaptured) && smoke.linesCaptured > 0 && smoke.validation?.passed === true,
  "smoke evidence does not report a passed embedded-swift-smoke-v2 run");

expect(proof.schemaVersion === 1 && proof.result === "passed" &&
  proof.proof === "real-external-firmware-consumer" && proof.proofRunId === proofRunId,
  "GO proof identity is invalid");
expect(proof.coreSha === expectedCoreSha && proof.contractSHA256 === manifest.contractSHA256 &&
  proof.firmwareSha256 === artifactHash && proof.device === "esp32c6",
  "GO proof Core, contract, artifact, or device identity is invalid");
expect(proof.core?.sourceDir === coreDir && proof.core.sha === expectedCoreSha && proof.core.dirty === false &&
  proof.core.contractSHA256 === manifest.contractSHA256 && proof.firmware?.sourceDir === firmwareDir &&
  proof.firmware.extractedRevision === expectedCoreSha,
  "GO proof provenance does not match the selected roots");
expect(proof.artifact?.path === artifact && proof.artifact.sha256 === artifactHash &&
  proof.artifact.byteCount === artifactBytes && proof.firmwareSha256 === artifactHash,
  "GO proof artifact does not match the re-hashed build output");
expect(proof.preparationManifest === path.join(evidenceDir, "preparation.json") &&
  proof.cleanRoomEvidence === path.join(evidenceDir, "clean-room.json") &&
  proof.deviceManifest === path.join(evidenceDir, "device-manifest.json") &&
  proof.smokeEvidence === path.join(evidenceDir, "swift-smoke-result.json"),
  "GO proof evidence links are invalid");
expect(proof.smoke?.runId === "embedded-swift-smoke-v2" && proof.smoke.device === device &&
  proof.smoke.validation?.passed === true && proof.checks?.artifactFlashed === true &&
  proof.checks?.smokeProtocol === "embedded-swift-smoke-v2",
  "GO proof does not include a passed flash and smoke record");

console.log(`proof evidence is complete for ${proofRunId}`);
