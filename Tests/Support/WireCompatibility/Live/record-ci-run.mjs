// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Update the small CI-owned record that accompanies a live-wire run.
 *
 * The record is deliberately not protocol evidence. It says what the gate
 * attempted and what it verified, including when no capture was attempted.
 * Updates are atomic so an interrupted workflow leaves the last truthful
 * state rather than a partially-written JSON document.
 */
export function updateRunRecord({
  file,
  phase,
  run = {},
  protocol,
  exempt,
  changedFileList,
  captureState,
  verificationState,
  jobStatus,
  inventoryPath,
  note,
}) {
  const record = readRecord(file);
  record.run = {
    ...record.run,
    ...Object.fromEntries(Object.entries(run).filter(([, value]) => value !== undefined)),
  };
  record.updatedAt = new Date().toISOString();
  record.lastPhase = phase;

  if (changedFileList !== undefined) {
    record.classification.changedFiles = readChangedFiles(changedFileList);
  }
  if (protocol !== undefined) {
    record.classification.protocolAffecting = parseTriState(protocol);
    record.classification.state = protocol === "1" ? "required" : protocol === "0" ? "fastpath" : "unknown";
  }
  if (exempt !== undefined) {
    record.classification.exempt = parseTriState(exempt);
    if (exempt === "1") record.classification.state = "exempt";
  }
  if (captureState !== undefined) {
    record.capture = { ...record.capture, state: captureState };
    if (captureState === "verified") record.captureEvidence = "verified";
    if (["failed", "unverified"].includes(captureState)) record.captureEvidence = "unverified";
  }
  if (verificationState !== undefined) {
    record.verification = { ...record.verification, state: verificationState };
    if (verificationState === "succeeded") record.captureEvidence = "verified";
    if (verificationState === "failed") record.captureEvidence = "unverified";
  }
  if (jobStatus !== undefined) record.job = { ...record.job, status: jobStatus };
  if (inventoryPath !== undefined) {
    record.diagnostics = { ...record.diagnostics, inventoryPath, ownedRuntimeInventory: true };
  }
  if (note !== undefined) record.notes = [...(record.notes ?? []), note];

  writeAtomically(file, `${JSON.stringify(record, null, 2)}\n`);
  return record;
}

function readRecord(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {
      format: "axoloty-wire-ci-run/v1",
      updatedAt: null,
      run: {},
      classification: {
        state: "pending",
        protocolAffecting: null,
        exempt: null,
        changedFiles: [],
      },
      capture: { state: "not-attempted" },
      verification: { state: "not-attempted" },
      // This is intentionally separate from the capture manifest. It must not
      // be mistaken for wire compatibility evidence.
      captureEvidence: "not-claimed",
      job: { status: "running" },
      diagnostics: { ownedRuntimeInventory: false },
      notes: [],
    };
  }
}

function readChangedFiles(file) {
  try {
    return fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean);
  } catch {
    return [];
  }
}

function parseTriState(value) {
  if (value === "1" || value === "true") return true;
  if (value === "0" || value === "false") return false;
  return null;
}

function writeAtomically(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, contents, { mode: 0o644 });
  fs.renameSync(temporary, file);
}

function option(args, name, fallback = undefined) {
  const index = args.indexOf(name);
  return index === -1 ? fallback : args[index + 1];
}

export function main(args = process.argv.slice(2)) {
  const file = option(args, "--file", ".testing/wire/ci/run-status.json");
  const phase = option(args, "--phase");
  if (!phase) throw new Error("--phase is required");
  updateRunRecord({
    file,
    phase,
    run: {
      id: option(args, "--run-id"),
      attempt: option(args, "--run-attempt"),
      event: option(args, "--event"),
      sha: option(args, "--sha"),
    },
    protocol: option(args, "--protocol"),
    exempt: option(args, "--exempt"),
    changedFileList: option(args, "--changed-file-list"),
    captureState: option(args, "--capture-state"),
    verificationState: option(args, "--verification-state"),
    jobStatus: option(args, "--job-status"),
    inventoryPath: option(args, "--inventory-path"),
    note: option(args, "--note"),
  });
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (error) {
    console.error(`wire CI run record failed: ${error.message}`);
    process.exitCode = 64;
  }
}
