// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const sha256 = data => crypto.createHash("sha256").update(data).digest("hex");
const nonEmpty = value => typeof value === "string" && value.trim().length > 0;
const integer = value => Number.isInteger(value) && value >= 0;

function expectedSubject(root) {
  const run = (args) => {
    return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
  };
  const version = fs.readFileSync(path.join(root, "VERSION"), "utf8").trim();
  return {
    repository: process.env.AXOLOTY_REPOSITORY ?? "github.com/phynics/axoloty",
    commit: run(["rev-parse", "HEAD"]),
    tree: run(["rev-parse", "HEAD^{tree}"]),
    version,
    clean: run(["status", "--porcelain"]) === "",
  };
}

function sameSubject(actual, expected) {
  return ["repository", "commit", "tree", "version", "clean"].every(key => actual?.[key] === expected[key]);
}

function validateArtifact(root, artifact, errors) {
  if (!artifact || !nonEmpty(artifact.path) || path.isAbsolute(artifact.path) || artifact.path.split(/[\\/]/).includes("..")) {
    errors.push(`invalid artifact path: ${JSON.stringify(artifact?.path)}`);
    return;
  }
  const absolute = path.resolve(root, artifact.path);
  if (absolute !== root && !absolute.startsWith(`${root}${path.sep}`)) {
    errors.push(`artifact escapes evidence root: ${artifact.path}`);
    return;
  }
  if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
    errors.push(`artifact missing: ${artifact.path}`);
    return;
  }
  const data = fs.readFileSync(absolute);
  if (!integer(artifact.byteCount) || artifact.byteCount !== data.length) errors.push(`artifact byteCount mismatch: ${artifact.path}`);
  if (!/^[0-9a-f]{64}$/.test(artifact.sha256 ?? "") || artifact.sha256 !== sha256(data)) errors.push(`artifact SHA-256 mismatch: ${artifact.path}`);
}

function validateRun(root, environment, run, index, errors) {
  const prefix = `${environment}.runs[${index}]`;
  if (!nonEmpty(run?.runID) || !nonEmpty(run?.compiler) || !nonEmpty(run?.optimization)) errors.push(`${prefix} requires runID, compiler, and optimization`);
  if (!nonEmpty(run?.sourceCommit) || !/^[0-9a-f]{40}$/.test(run.sourceCommit)) errors.push(`${prefix}.sourceCommit must be a full commit SHA`);
  if (!nonEmpty(run?.policyDigest)) errors.push(`${prefix}.policyDigest is required`);
  if (!nonEmpty(run?.board) || !nonEmpty(run?.container) || !nonEmpty(run?.corpusDigest) || !nonEmpty(run?.sourceSetDigest)) {
    errors.push(`${prefix} requires board, container, corpusDigest, and sourceSetDigest identity`);
  }
  if (!run?.measurements || typeof run.measurements !== "object" || Array.isArray(run.measurements)) errors.push(`${prefix}.measurements are required`);
  for (const artifact of run?.artifacts ?? []) validateArtifact(root, artifact, errors);
  if (!Array.isArray(run?.artifacts) || run.artifacts.length === 0) errors.push(`${prefix}.artifacts must be non-empty`);
}

export function validate(document, { root, repositoryRoot = root, subject = expectedSubject(repositoryRoot) } = {}) {
  const errors = [];
  if (document?.schemaVersion !== 1) errors.push("schemaVersion must be 1");
  if (document?.gate !== "g6-resource-evidence") errors.push("gate must be g6-resource-evidence");
  if (!document?.subject || !sameSubject(document.subject, subject)) errors.push("evidence subject does not match the exact checkout");
  if (document?.subject?.clean !== true) errors.push("resource evidence requires a clean subject");
  if (document?.approval?.status !== "approved" || !nonEmpty(document?.approval?.policyDigest)) errors.push("approved resource policy and policyDigest are required");
  const host = document?.environments?.host;
  const device = document?.environments?.esp32c6;
  if (!host || !Array.isArray(host.runs) || host.runs.length < 2) errors.push("host requires at least two independent runs");
  if (!device || !Array.isArray(device.runs) || device.runs.length < 2) errors.push("esp32c6 requires at least two power-cycle runs");
  for (const [index, run] of (host?.runs ?? []).entries()) validateRun(root, "host", run, index, errors);
  for (const [index, run] of (device?.runs ?? []).entries()) validateRun(root, "esp32c6", run, index, errors);
  for (const [environment, value] of [["host", host], ["esp32c6", device]]) {
    const ids = (value?.runs ?? []).map(run => run?.runID).filter(nonEmpty);
    if (new Set(ids).size !== ids.length) errors.push(`${environment}.runs must use independent runIDs`);
    for (const run of value?.runs ?? []) {
      if (run?.sourceCommit !== subject.commit) errors.push(`${environment}.${run?.runID ?? "run"} sourceCommit differs from the exact subject commit`);
      if (run?.policyDigest !== document?.approval?.policyDigest) errors.push(`${environment}.${run?.runID ?? "run"} policyDigest differs from the approved policy`);
    }
  }
  if (device?.implementation !== "embedded-swift") errors.push("esp32c6 implementation must be embedded-swift");
  if (device?.historicalEvidence === "esp32c6-c-surrogate" || device?.cSurrogate === true) errors.push("C surrogate evidence is never release eligible");
  if (!integer(device?.powerCycleRuns) || device.powerCycleRuns < 2) errors.push("powerCycleRuns must be at least 2");
  if (!integer(device?.sustainedWorkload?.durationSeconds) || device.sustainedWorkload.durationSeconds < 600) errors.push("sustained workload must run for at least ten minutes");
  if (!integer(device?.sustainedWorkload?.messageRatePerSecond) || device.sustainedWorkload.messageRatePerSecond < 100) errors.push("sustained workload must cover at least 100 messages/second");
  if (!integer(device?.sustainedWorkload?.measuredCapacityPerSecond) || device.sustainedWorkload.measuredCapacityPerSecond < 125) errors.push("measured capacity must provide at least 125 messages/second headroom");
  return { errors };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const evidence = path.resolve(process.argv[2] ?? "");
  const root = path.resolve(process.argv[3] ?? process.cwd());
  const repositoryRoot = path.resolve(process.argv[4] ?? root);
  const document = JSON.parse(fs.readFileSync(evidence, "utf8"));
  const report = validate(document, { root, repositoryRoot });
  process.stdout.write(`${JSON.stringify({ schemaVersion: 1, status: report.errors.length ? "failed" : "passed", errors: report.errors })}\n`);
  if (report.errors.length) process.exitCode = 1;
}
