// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
// Decide whether a change set is protocol-affecting for the CI live-wire gate.
//
// This is the single source of truth for which paths carry live wire
// semantics (issue #457). Keep `PROTOCOL_AFFECTING` rules in sync with
// `docs/wire-compatibility.md`.

import { fileURLToPath } from "node:url";

export const PROTOCOL_AFFECTING = [
  { glob: "Packages/AxolotyWire/**", description: "AxolotyWire codec and routing" },
  { glob: "Source/**", description: "host wire codecs, events, core types, IO, SensorThings" },
  { glob: "Tests/AxolotyTests/WireCompatibility/**", description: "offline wire tests and fixtures" },
  { glob: "Tests/AxolotyLiveWireTests/**", description: "live wire Swift subjects" },
  { glob: "Tests/Support/WireCompatibility/**", description: "wire scenarios, reference agents, and tooling" },
  { glob: "Tests/AxolotyWire/**", description: "wire codec tests" },
  { glob: "Package.swift", description: "package manifest" },
  { glob: "Package.resolved", description: "resolved dependency graph" },
];

// Test orchestration and CI tooling policy do not change the bytes that flow
// across an MQTT wire, so they stay on the fast path: tuning the canonical
// test manifest or the tooling lifecycle is not itself live wire evidence.
// (These were considered for issue #457 and deliberately excluded.)

// Documentation subpaths that never affect the wire contract. Any Markdown,
// RST, or decision record under the wire tree, and the DocC documentation
// tree, stay on the fast path; only executable wire evidence paths trigger the
// live gate.
export const NON_PROTOCOL_EXCLUSIONS = [
  "Source/Axoloty.docc/**",
  "Tests/Support/WireCompatibility/Audit/**",
];

function globToRegex(glob) {
  if (glob.endsWith("/**")) {
    const base = glob.slice(0, -3);
    const escaped = base.split("*").map(part => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*");
    return new RegExp(`^${escaped}(?:/.*)?$`);
  }
  const escaped = glob.split("*").map(part => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*");
  return new RegExp(`^${escaped}$`);
}

function isExcluded(normalized) {
  if (NON_PROTOCOL_EXCLUSIONS.some(rule => globToRegex(rule).test(normalized))) {
    return true;
  }
  // Documentation and decision records under the wire tree are not wire
  // evidence; executable fixtures and scenario code are.
  if ((normalized.startsWith("Tests/AxolotyTests/WireCompatibility/")
      || normalized.startsWith("Tests/AxolotyLiveWireTests/")
      || normalized.startsWith("Tests/Support/WireCompatibility/"))
      && /\.(md|rst)$/.test(normalized)) {
    return true;
  }
  return false;
}

const MATCHES = PROTOCOL_AFFECTING.map(rule => ({ ...rule, regex: globToRegex(rule.glob) }));

/** Is a repository-relative path protocol-affecting? */
export function isProtocolAffecting(file) {
  const normalized = file.replace(/^\.\//, "").replace(/^\/+/, "");
  if (isExcluded(normalized)) {
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
    console.log("gate=require");
    console.log(`protocol-affecting: ${result.files.length} changed path(s) require live wire evidence`);
    for (const file of result.files) {
      const rule = MATCHES.find(candidate => candidate.regex.test(file));
      console.log(`  - ${file} (${rule?.description ?? "matched rule"})`);
    }
    if (result.exempt) {
      console.log(`exemption recorded: ${exempt}`);
    }
  } else {
    console.log("gate=fastpath");
    console.log("no protocol-affecting paths changed; live wire gate not required");
  }
  const exitCode = result.protocolAffecting && !result.exempt ? 1 : 0;
  return exitCode;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main();
