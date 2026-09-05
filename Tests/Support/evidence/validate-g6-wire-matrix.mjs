// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const digest = data => crypto.createHash("sha256").update(data).digest("hex");

function exactCells(cells, expected) {
  const sortedExpected = [...expected].sort();
  return Array.isArray(cells)
    && cells.length === sortedExpected.length
    && new Set(cells).size === cells.length
    && [...cells].sort().every((cell, index) => cell === sortedExpected[index]);
}

function subjectFor(root) {
  const git = args => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
  return {
    repository: process.env.AXOLOTY_REPOSITORY ?? "github.com/phynics/axoloty",
    commit: git(["rev-parse", "HEAD"]),
    tree: git(["rev-parse", "HEAD^{tree}"]),
    version: fs.readFileSync(path.join(root, "VERSION"), "utf8").trim(),
    clean: git(["status", "--porcelain"]) === "",
  };
}

function validateArtifact(root, artifact, errors) {
  if (!artifact || typeof artifact.path !== "string" || path.isAbsolute(artifact.path) || artifact.path.split(/[\\/]/).includes("..")) {
    errors.push(`invalid artifact path: ${JSON.stringify(artifact?.path)}`);
    return;
  }
  const file = path.resolve(root, artifact.path);
  if (!file.startsWith(`${root}${path.sep}`) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    errors.push(`missing artifact: ${artifact.path}`);
    return;
  }
  const data = fs.readFileSync(file);
  if (artifact.byteCount !== data.length || artifact.sha256 !== digest(data)) errors.push(`artifact digest mismatch: ${artifact.path}`);
}

export function validateMatrix(matrix, evidence, { root, repositoryRoot = root, subject, matrixDigest } = {}) {
  const errors = [];
  if (matrix?.schemaVersion !== 1 || typeof matrix?.matrixVersion !== "string") errors.push("matrix schema is unsupported");
  if (!Array.isArray(matrix?.requiredCells) || new Set(matrix.requiredCells).size !== matrix.requiredCells.length) errors.push("requiredCells must be a unique array");
  const expected = Array.isArray(matrix?.requiredCells) ? matrix.requiredCells : [];
  if (evidence) {
    const expectedSubject = subject ?? subjectFor(repositoryRoot);
    if (evidence.schemaVersion !== 1 || evidence.matrixVersion !== matrix.matrixVersion) errors.push("evidence schema or matrix version mismatch");
    if (JSON.stringify(evidence.subject) !== JSON.stringify(expectedSubject)) errors.push("evidence subject does not match exact checkout");
    if (evidence.subject?.clean !== true) errors.push("matrix evidence requires a clean subject");
    if (matrixDigest && evidence.matrixDigest !== matrixDigest) errors.push("evidence does not identify the exact scenario-matrix digest");
    if (evidence.status !== "passed") errors.push("matrix evidence must have passed status");
    const identity = evidence.identity;
    if (identity?.axoloty?.commit !== expectedSubject.commit || !/^[0-9a-f]{64}$/.test(identity?.axoloty?.executableDigest ?? "")) {
      errors.push("evidence must bind the Axoloty commit and executable digest");
    }
    if (!identity?.coatyjs?.revision || !identity?.coatyjs?.packageIntegrity || !identity?.coatyjs?.lockfileDigest) {
      errors.push("evidence must bind the pinned CoatyJS revision, package integrity, and lockfile digest");
    }
    if (!identity?.broker?.image || !identity?.broker?.digest) errors.push("evidence must identify the broker image and digest");
    const evidenceCells = Array.isArray(evidence.cells) ? evidence.cells : [];
    if (!Array.isArray(evidence.cells)) errors.push("evidence cells must be an array");
    if (!exactCells(evidenceCells.map(cell => cell?.id), expected)) errors.push("evidence cells do not exactly equal required matrix cells");
    const seen = new Set();
    for (const cell of evidenceCells) {
      if (!cell || typeof cell !== "object" || Array.isArray(cell)) {
        errors.push("evidence cell must be an object");
        continue;
      }
      if (seen.has(cell.id)) errors.push(`duplicate evidence cell: ${cell.id}`);
      seen.add(cell.id);
      if (!["passed", "rejected"].includes(cell.outcome)) errors.push(`${cell.id}: outcome must be passed or rejected`);
      const logs = Array.isArray(cell.logs) ? cell.logs : [];
      const artifacts = Array.isArray(cell.artifacts) ? cell.artifacts : [];
      if (!Array.isArray(cell.logs) || !["broker", "axoloty", "coatyjs"].every(kind => logs.some(log => log?.kind === kind))) errors.push(`${cell.id}: broker, axoloty, and coatyjs logs are required`);
      if (!Array.isArray(cell.artifacts) || artifacts.length === 0) errors.push(`${cell.id}: normalized capture artifacts are required`);
      for (const artifact of [...artifacts, ...logs]) validateArtifact(root, artifact, errors);
      if (cell.outcome === "rejected" && !cell.expectedRejection) errors.push(`${cell.id}: rejected cells require expectedRejection`);
    }
  }
  return { errors };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const matrix = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), "utf8"));
  const evidencePath = process.argv[3];
  const evidence = evidencePath ? JSON.parse(fs.readFileSync(path.resolve(evidencePath), "utf8")) : undefined;
  const root = path.resolve(process.argv[4] ?? process.cwd());
  const repositoryRoot = path.resolve(process.argv[5] ?? root);
  const matrixDigest = digest(fs.readFileSync(path.resolve(process.argv[2])));
  const report = validateMatrix(matrix, evidence, { root, repositoryRoot, matrixDigest });
  process.stdout.write(`${JSON.stringify({ schemaVersion: 1, status: report.errors.length ? "failed" : "passed", errors: report.errors })}\n`);
  if (report.errors.length) process.exitCode = 1;
}
