// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const sha256 = data => crypto.createHash("sha256").update(data).digest("hex");
const nonEmpty = value => typeof value === "string" && value.trim().length > 0;
const integer = value => Number.isInteger(value) && value >= 0;

function loadPolicy(policyPath, errors) {
  if (!nonEmpty(policyPath) || !fs.existsSync(policyPath)) {
    errors.push(`resource policy is missing: ${policyPath}`);
    return null;
  }
  try {
    const data = fs.readFileSync(policyPath);
    return { document: JSON.parse(data), digest: sha256(data) };
  } catch (error) {
    errors.push(`resource policy is not readable JSON: ${error.message}`);
    return null;
  }
}

function validatePolicy(policy, errors) {
  if (policy?.schemaVersion !== 1) errors.push("resource policy schemaVersion must be 1");
  if (policy?.gate !== "g6-resource-evidence") errors.push("resource policy gate must be g6-resource-evidence");
  if (policy?.approval?.status !== "approved") errors.push("resource policy approval status must be approved");
  for (const environment of ["host", "esp32c6"]) {
    const definition = policy?.environments?.[environment];
    if (!integer(definition?.minimumRuns) || definition.minimumRuns < 2) {
      errors.push(`resource policy ${environment}.minimumRuns must be at least 2`);
    }
    if (!Array.isArray(definition?.requiredMeasurements) || definition.requiredMeasurements.length === 0 || !definition.requiredMeasurements.every(nonEmpty)) {
      errors.push(`resource policy ${environment}.requiredMeasurements must be a non-empty string list`);
    }
  }
  const device = policy?.environments?.esp32c6;
  if (device?.implementation !== "embedded-swift") errors.push("resource policy esp32c6 implementation must be embedded-swift");
  for (const [metric, threshold] of Object.entries(device?.thresholds ?? {})) {
    if (!nonEmpty(metric) || !threshold || typeof threshold !== "object" || Array.isArray(threshold)) {
      errors.push(`resource policy threshold is invalid: ${metric}`);
      continue;
    }
    const hasMinimum = Object.hasOwn(threshold, "minimum");
    const hasMaximum = Object.hasOwn(threshold, "maximum");
    if ((!hasMinimum && !hasMaximum) || (hasMinimum && !integer(threshold.minimum)) || (hasMaximum && !integer(threshold.maximum)) ||
      (hasMinimum && hasMaximum && threshold.minimum > threshold.maximum)) {
      errors.push(`resource policy threshold is invalid: ${metric}`);
    }
  }
  const workload = device?.sustainedWorkload;
  for (const field of ["minimumDurationSeconds", "minimumMessageRatePerSecond", "minimumMeasuredCapacityPerSecond"]) {
    if (!integer(workload?.[field]) || workload[field] === 0) errors.push(`resource policy sustainedWorkload.${field} must be positive`);
  }
}

function expectedSubject(root) {
  const run = (args) => {
    return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
  };
  const version = fs.readFileSync(path.join(root, "VERSION"), "utf8").trim();
  return {
    repository: process.env.AXOLOTY_REPOSITORY?.trim() || "github.com/phynics/axoloty",
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

function validateRun(root, environment, run, index, measurementPolicy, errors) {
  const prefix = `${environment}.runs[${index}]`;
  if (!nonEmpty(run?.runID) || !nonEmpty(run?.compiler) || !nonEmpty(run?.optimization)) errors.push(`${prefix} requires runID, compiler, and optimization`);
  if (!nonEmpty(run?.sourceCommit) || !/^[0-9a-f]{40}$/.test(run.sourceCommit)) errors.push(`${prefix}.sourceCommit must be a full commit SHA`);
  if (!nonEmpty(run?.policyDigest)) errors.push(`${prefix}.policyDigest is required`);
  if (!nonEmpty(run?.board) || !nonEmpty(run?.container) || !nonEmpty(run?.corpusDigest) || !nonEmpty(run?.sourceSetDigest)) {
    errors.push(`${prefix} requires board, container, corpusDigest, and sourceSetDigest identity`);
  }
  if (!run?.measurements || typeof run.measurements !== "object" || Array.isArray(run.measurements)) {
    errors.push(`${prefix}.measurements are required`);
  } else {
    for (const metric of measurementPolicy.requiredMeasurements ?? []) {
      if (!integer(run.measurements[metric])) errors.push(`${prefix}.measurements.${metric} must be a non-negative integer`);
    }
    for (const [metric, threshold] of Object.entries(measurementPolicy.thresholds ?? {})) {
      const measured = run.measurements[metric];
      if (integer(threshold.minimum) && measured < threshold.minimum) errors.push(`${prefix}.measurements.${metric} is below its approved minimum`);
      if (integer(threshold.maximum) && measured > threshold.maximum) errors.push(`${prefix}.measurements.${metric} exceeds its approved maximum`);
    }
  }
  if (Array.isArray(run?.artifacts)) {
    for (const artifact of run.artifacts) validateArtifact(root, artifact, errors);
  }
  if (!Array.isArray(run?.artifacts) || run.artifacts.length === 0) errors.push(`${prefix}.artifacts must be non-empty`);
}

export function validate(document, { root, repositoryRoot = root, policyPath = path.join(repositoryRoot, "Tests/Support/evidence/g6-resource-policy.json"), subject = expectedSubject(repositoryRoot) } = {}) {
  const errors = [];
  const policy = loadPolicy(policyPath, errors);
  if (policy) validatePolicy(policy.document, errors);
  if (document?.schemaVersion !== 1) errors.push("schemaVersion must be 1");
  if (document?.gate !== "g6-resource-evidence") errors.push("gate must be g6-resource-evidence");
  if (!document?.subject || !sameSubject(document.subject, subject)) errors.push("evidence subject does not match the exact checkout");
  if (document?.subject?.clean !== true) errors.push("resource evidence requires a clean subject");
  if (document?.approval?.status !== policy?.document?.approval?.status || document?.approval?.policyDigest !== policy?.digest) {
    errors.push("evidence approval must name the exact approved resource policy");
  }
  const host = document?.environments?.host;
  const device = document?.environments?.esp32c6;
  if (!host || !Array.isArray(host.runs) || host.runs.length < (policy?.document?.environments?.host?.minimumRuns ?? Infinity)) errors.push("host requires the approved number of independent runs");
  if (!device || !Array.isArray(device.runs) || device.runs.length < (policy?.document?.environments?.esp32c6?.minimumRuns ?? Infinity)) errors.push("esp32c6 requires the approved number of power-cycle runs");
  for (const [index, run] of (host?.runs ?? []).entries()) validateRun(root, "host", run, index, policy?.document?.environments?.host ?? {}, errors);
  for (const [index, run] of (device?.runs ?? []).entries()) validateRun(root, "esp32c6", run, index, policy?.document?.environments?.esp32c6 ?? {}, errors);
  for (const [environment, value] of [["host", host], ["esp32c6", device]]) {
    const ids = (value?.runs ?? []).map(run => run?.runID).filter(nonEmpty);
    if (new Set(ids).size !== ids.length) errors.push(`${environment}.runs must use independent runIDs`);
    for (const run of value?.runs ?? []) {
      if (run?.sourceCommit !== subject.commit) errors.push(`${environment}.${run?.runID ?? "run"} sourceCommit differs from the exact subject commit`);
      if (run?.policyDigest !== document?.approval?.policyDigest) errors.push(`${environment}.${run?.runID ?? "run"} policyDigest differs from the approved policy`);
    }
  }
  if (device?.implementation !== policy?.document?.environments?.esp32c6?.implementation) errors.push("esp32c6 implementation must match the approved policy");
  if (device?.historicalEvidence === "esp32c6-c-surrogate" || device?.cSurrogate === true) errors.push("C surrogate evidence is never release eligible");
  if (!integer(device?.powerCycleRuns) || device.powerCycleRuns < (policy?.document?.environments?.esp32c6?.minimumRuns ?? Infinity)) errors.push("powerCycleRuns must meet the approved policy");
  const workload = policy?.document?.environments?.esp32c6?.sustainedWorkload;
  if (!integer(device?.sustainedWorkload?.durationSeconds) || device.sustainedWorkload.durationSeconds < (workload?.minimumDurationSeconds ?? Infinity)) errors.push("sustained workload duration does not meet the approved policy");
  if (!integer(device?.sustainedWorkload?.messageRatePerSecond) || device.sustainedWorkload.messageRatePerSecond < (workload?.minimumMessageRatePerSecond ?? Infinity)) errors.push("sustained workload rate does not meet the approved policy");
  if (!integer(device?.sustainedWorkload?.measuredCapacityPerSecond) || device.sustainedWorkload.measuredCapacityPerSecond < (workload?.minimumMeasuredCapacityPerSecond ?? Infinity)) errors.push("measured capacity does not meet the approved policy");
  return { errors };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const evidence = path.resolve(process.argv[2] ?? "");
  const root = path.resolve(process.argv[3] ?? process.cwd());
  const repositoryRoot = path.resolve(process.argv[4] ?? root);
  const policyPath = path.resolve(process.argv[5] ?? path.join(repositoryRoot, "Tests/Support/evidence/g6-resource-policy.json"));
  const document = JSON.parse(fs.readFileSync(evidence, "utf8"));
  const report = validate(document, { root, repositoryRoot, policyPath });
  process.stdout.write(`${JSON.stringify({ schemaVersion: 1, status: report.errors.length ? "failed" : "passed", errors: report.errors })}\n`);
  if (report.errors.length) process.exitCode = 1;
}
