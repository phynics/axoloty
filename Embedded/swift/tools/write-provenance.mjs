// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const [manifestPath, artifactPath, outputPath, firmwareRoot, buildRoot, cleanRoomPath] = process.argv.slice(2);
if (![manifestPath, artifactPath, outputPath, firmwareRoot, buildRoot, cleanRoomPath].every(Boolean)) {
  console.error("usage: write-provenance.mjs manifest artifact output firmware-root build-root clean-room");
  process.exit(64);
}

const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const manifest = read(manifestPath);
const cleanRoom = read(cleanRoomPath);
const canonical = value => fs.realpathSync(value);
const coreRoot = canonical(manifest.core.sourceDir);
const firmware = canonical(firmwareRoot);
const artifact = canonical(artifactPath);
if (manifest.status !== "prepared" || manifest.core.dirty !== false) {
  throw new Error("cannot write build provenance from an unprepared or dirty Core");
}
const relative = (root, candidate) => {
  const value = path.relative(root, candidate);
  if (value.startsWith("..") || path.isAbsolute(value)) throw new Error(`path escapes root: ${candidate}`);
  return value;
};
const coreFromFirmware = path.relative(firmware, coreRoot);
const firmwareFromCore = path.relative(coreRoot, firmware);
if ((!coreFromFirmware.startsWith("..") && !path.isAbsolute(coreFromFirmware)) ||
    (!firmwareFromCore.startsWith("..") && !path.isAbsolute(firmwareFromCore))) {
  throw new Error("Core and firmware roots overlap");
}

const command = (executable, args) => {
  try {
    return execFileSync(executable, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
};
const sha256 = crypto.createHash("sha256").update(fs.readFileSync(artifact)).digest("hex");
const firmwareRevision = command("git", ["-C", firmware, "rev-parse", "HEAD"]);
const firmwareDirty = command("git", ["-C", firmware, "status", "--porcelain"]) !== null
  ? command("git", ["-C", firmware, "status", "--porcelain"]) !== ""
  : null;
const extractedRevision = fs.readFileSync(path.join(firmware, ".axoloty-source-revision"), "utf8").trim();
if (extractedRevision !== manifest.core.sha) {
  throw new Error("firmware extraction revision differs from Core provenance");
}
const output = {
  schemaVersion: 1,
  status: "passed",
  proof: "real-external-firmware-consumer",
  proofRunId: process.env.AXOLOTY_PROOF_RUN_ID ?? "manual",
  core: {
    sourceDir: coreRoot,
    sha: manifest.core.sha,
    dirty: manifest.core.dirty,
    contractSHA256: manifest.contractSHA256,
  },
  firmware: {
    sourceDir: firmware,
    revision: firmwareRevision,
    extractedRevision,
    dirty: firmwareDirty,
    sourceCopied: false,
  },
  preparationManifest: manifestPath,
  cleanRoomEvidence: cleanRoomPath,
  portablePackages: manifest.portablePackages,
  jsonCore: manifest.jsonCore,
  staticRuntimeMacro: manifest.staticRuntimeMacro,
  toolchain: {
    target: "esp32c6",
    swift: command("swift", ["--version"]),
    espIdf: command("idf.py", ["--version"]),
    parallelism: process.env.CMAKE_BUILD_PARALLEL_LEVEL ?? null,
  },
  artifact: {
    path: artifact,
    relativePath: relative(canonical(buildRoot), artifact),
    sha256,
    byteCount: fs.statSync(artifact).size,
  },
  firmwareSha256: sha256,
  checks: {
    privateReferenceScan: cleanRoom.privateReferenceScan,
    manifestSchema: manifest.schemaVersion,
    coreFirmwareRootsDisjoint: true,
  },
};
const temporary = `${outputPath}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(temporary, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, outputPath);
