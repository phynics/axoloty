// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
// Decide whether a change set is protocol-affecting for the CI live-wire gate.
//
// This is the single source of truth for which paths carry live wire
// semantics (issue #457). Keep `PROTOCOL_AFFECTING` rules in sync with
// `Tests/WireCompatibility/CompatibilityMatrix.md`.

import { fileURLToPath } from "node:url";

export const PROTOCOL_AFFECTING = [
  { glob: "Packages/AxolotyWire/**", description: "AxolotyWire codec and routing" },
  { glob: "Source/**", description: "host wire codecs, events, core types, IO, SensorThings" },
  { glob: "Tests/WireCompatibility/**", description: "wire fixtures, reference agents, scenarios" },
  { glob: "Tests/AxolotyWire/**", description: "wire codec tests" },
  { glob: "Tests/Support/test-tiers.json", description: "canonical test contract" },
  { glob: "Package.swift", description: "package manifest" },
  { glob: "Package.resolved", description: "resolved dependency graph" },
  { glob: "Tools/AxolotyTooling/**", description: "canonical tooling and policy" },
];

// Documentation subpaths under Source that never affect the wire contract.
export const NON_PROTOCOL_EXACT = new Set([
  "Source/Axoloty.docc",
]);

function globToRegex(glob) {
  if (glob.endsWith("/**")) {
    const base = glob.slice(0, -3);
    const escaped = base.split("*").map(part => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*");
    return new RegExp(`^${escaped}(?:/.*)?$`);
  }
  const escaped = glob.split("*").map(part => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*");
  return new RegExp(`^${escaped}$`);
}

const MATCHES = PROTOCOL_AFFECTING.map(rule => ({ ...rule, regex: globToRegex(rule.glob) }));

/** Is a repository-relative path protocol-affecting? */
export function isProtocolAffecting(file) {
  const normalized = file.replace(/^\.\//, "").replace(/^\/+/, "");
  if ([...NON_PROTOCOL_EXACT].some(prefix => normalized === prefix || normalized.startsWith(`${prefix}/`))) {
    return false;
  }
  return MATCHES.some(rule => rule.regex.test(normalized));
}

/**
 * Classify a list of repository-relative changed paths.
 *
 * @param changedFiles Changed file paths.
 * @param exempt Reference to a recorded exemption (issue number, PR, or link),
 *   when present. An exemption skips the live gate only if it cites a recorded
 *   decision; it is recorded, not counted as a protocol-affecting pass.
 */
export function classify(changedFiles, exempt = null) {
  const affected = changedFiles.filter(isProtocolAffecting);
  return {
    protocolAffecting: affected.length > 0,
    files: affected,
    exempt: Boolean(exempt && exempt.trim()),
  };
}

export function main(argumentsArray = process.argv.slice(2)) {
  // Usage: classify-wire-change.mjs --changed "file1 file2..." [--exempt "ref"]
  let changed = null;
  let exempt = null;
  for (let i = 0; i < argumentsArray.length; i += 1) {
    const arg = argumentsArray[i];
    if (arg === "--changed") changed = argumentsArray[i + 1] ?? "";
    else if (arg === "--exempt") exempt = argumentsArray[i + 1] ?? "";
  }
  const files = (changed ?? "").split(/\s+/).filter(Boolean);
  const result = classify(files, exempt);
  if (result.protocolAffecting) {
    console.log(`protocol-affecting: ${result.files.length} changed path(s) require live wire evidence`);
    for (const file of result.files) {
      const rule = MATCHES.find(candidate => candidate.regex.test(file));
      console.log(`  - ${file} (${rule?.description ?? "matched rule"})`);
    }
    if (result.exempt) {
      console.log(`exemption recorded: ${exempt}`);
    }
  } else {
    console.log("no protocol-affecting paths changed; live wire gate not required");
  }
  const exitCode = result.protocolAffecting && !result.exempt ? 1 : 0;
  return exitCode;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main();