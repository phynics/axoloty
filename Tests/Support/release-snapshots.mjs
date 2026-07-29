// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const format = "axoloty-wire-snapshot-bundle/v1";

function command(executable, arguments_, fallback = "unknown") {
  try {
    return execFileSync(executable, arguments_, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return fallback;
  }
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function capturesBelow(directory, prefix = "") {
  return fs.readdirSync(directory, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name))
    .flatMap(entry => {
      const relative = path.join(prefix, entry.name);
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) return capturesBelow(absolute, relative);
      return entry.isFile() && entry.name.endsWith(".jsonl") ? [relative] : [];
    });
}

function captureMetadata(bytes, file) {
  const records = bytes.toString("utf8").split("\n").filter(line => line.trim()).map((line, index) => {
    let record;
    try {
      record = JSON.parse(line);
    } catch (error) {
      throw new Error(`${file}: invalid JSON record ${index + 1}: ${error.message}`);
    }
    if (record.format !== "coaty-wire-capture/v1"
      || typeof record.mqtt?.topic !== "string"
      || record.payload?.encoding !== "base64"
      || typeof record.payload?.bytes !== "string"
      || typeof record.normalizationProfile !== "string") {
      throw new Error(`${file}: record ${index + 1} does not satisfy coaty-wire-capture/v1`);
    }
    if (record.sequence !== index + 1) {
      throw new Error(`${file}: expected sequence ${index + 1}, got ${record.sequence}`);
    }
    return record;
  });
  if (!records.length) throw new Error(`${file}: capture contains no records`);
  return {
    recordCount: records.length,
    producer: records[0].producer,
    scenario: records[0].scenario,
    normalizationProfiles: [...new Set(records.map(record => record.normalizationProfile))].sort(),
  };
}

function generatedAt(environment) {
  const epoch = environment.SOURCE_DATE_EPOCH;
  if (epoch !== undefined && /^\d+$/.test(epoch)) return new Date(Number(epoch) * 1000).toISOString();
  return new Date().toISOString();
}

export function generateBundle(source, destination, environment = process.env) {
  const files = capturesBelow(source);
  if (!files.length) throw new Error(`no JSONL captures found in ${source}`);
  fs.rmSync(destination, { recursive: true, force: true });
  fs.mkdirSync(path.join(destination, "captures"), { recursive: true });
  const captures = files.map(file => {
    const bytes = fs.readFileSync(path.join(source, file));
    const output = path.join(destination, "captures", file);
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, bytes);
    return { file: path.join("captures", file), sha256: sha256(bytes), ...captureMetadata(bytes, file) };
  });
  const normalizationSource = environment.AXOLOTY_NORMALIZATION_RULES
    ?? "Tests/WireCompatibility/Capture/normalization-rules.json";
  if (!fs.existsSync(normalizationSource)) throw new Error(`normalization rules not found: ${normalizationSource}`);
  const normalizationBytes = fs.readFileSync(normalizationSource);
  fs.writeFileSync(path.join(destination, "normalization-rules.json"), normalizationBytes);
  const packageResolved = fs.existsSync("Package.resolved") ? fs.readFileSync("Package.resolved") : Buffer.alloc(0);
  const manifest = {
    format,
    generatedAt: generatedAt(environment),
    provenance: {
      gitCommit: environment.AXOLOTY_GIT_COMMIT ?? command("git", ["rev-parse", "HEAD"]),
      gitClean: environment.AXOLOTY_GIT_CLEAN
        ?? (command("git", ["status", "--porcelain"], "dirty") === "" ? "true" : "false"),
      swiftVersion: command("swift", ["--version"]),
      nodeVersion: process.version,
      imageIdentity: environment.AXOLOTY_IMAGE_IDENTITY ?? environment.IMAGE ?? "native",
      packageResolvedSHA256: packageResolved.length ? sha256(packageResolved) : "unavailable",
    },
    normalizationRules: {
      file: "normalization-rules.json",
      sha256: sha256(normalizationBytes),
    },
    verification: {
      command: "ax wire verify",
      semantics: "Swift fixture tests decode byte-exact topics and base64 payloads offline",
    },
    captures,
  };
  fs.writeFileSync(path.join(destination, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

export function verifyBundle(directory) {
  const manifestPath = path.join(directory, "manifest.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (manifest.format !== format || !Array.isArray(manifest.captures) || !manifest.captures.length) {
    throw new Error("unsupported or empty snapshot manifest");
  }
  const normalizationBytes = fs.readFileSync(path.join(directory, manifest.normalizationRules.file));
  if (sha256(normalizationBytes) !== manifest.normalizationRules.sha256) {
    throw new Error("SHA-256 mismatch: normalization-rules.json");
  }
  for (const capture of manifest.captures) {
    const file = path.resolve(directory, capture.file);
    const root = `${path.resolve(directory)}${path.sep}`;
    if (!file.startsWith(root)) throw new Error(`capture escapes bundle: ${capture.file}`);
    const bytes = fs.readFileSync(file);
    if (sha256(bytes) !== capture.sha256) throw new Error(`SHA-256 mismatch: ${capture.file}`);
    const metadata = captureMetadata(bytes, capture.file);
    if (metadata.recordCount !== capture.recordCount
      || metadata.scenario !== capture.scenario
      || JSON.stringify(metadata.producer) !== JSON.stringify(capture.producer)
      || JSON.stringify(metadata.normalizationProfiles) !== JSON.stringify(capture.normalizationProfiles)) {
      throw new Error(`metadata mismatch: ${capture.file}`);
    }
  }
  return manifest;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const [operation, first, second] = process.argv.slice(2);
    const result = operation === "generate"
      ? generateBundle(first, second)
      : operation === "verify"
        ? verifyBundle(first)
        : (() => { throw new Error("usage: release-snapshots.mjs <generate SOURCE OUTPUT|verify BUNDLE>"); })();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`RELEASE SNAPSHOTS FAIL: ${error.message}\n`);
    process.exitCode = 1;
  }
}
