// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const expectedTiers = new Set(["smoke", "unit", "module", "property", "integration", "wire-offline", "wire-live", "nightly", "manual-macos"]);
const networkModes = new Set(["none", "isolated", "isolated-broker", "isolated-containers"]);

export function parseMakeTargets(makefilePath) {
  if (!fs.existsSync(makefilePath)) return new Set();
  const targets = new Set();
  for (const line of fs.readFileSync(makefilePath, "utf8").split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_][A-Za-z0-9_.-]*):(?!=)/.exec(line);
    if (match && !match[1].startsWith(".")) targets.add(match[1]);
  }
  return targets;
}

function shellTokenMatchesPath(token, selfTestPath) {
  const unquoted = token.replace(/^["']|["']$/g, "");
  const repositoryPath = unquoted.replace(/^\/workspace\//, "");
  if (repositoryPath === selfTestPath) return true;
  if (!repositoryPath.includes("*")) return false;
  const pattern = repositoryPath.split("*").map(segment => segment.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*");
  return new RegExp(`^${pattern}$`).test(selfTestPath);
}

function commandInvokesSelfTest(command, selfTestPath) {
  const tokens = command.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) ?? [];
  if (tokens.some(token => !token.includes("*") && shellTokenMatchesPath(token, selfTestPath))) return true;
  const nodeTest = tokens.findIndex((token, index) => token === "node" && tokens[index + 1] === "--test" && (index === 0 || tokens[index - 1] === "&&"));
  return nodeTest >= 0 && tokens.slice(nodeTest + 2).some(token => token.includes("*") && shellTokenMatchesPath(token, selfTestPath));
}

export function discoverTargetSelfTests(makefilePath, selfTests) {
  if (!fs.existsSync(makefilePath)) return new Map();
  const invoked = new Map();
  let target;
  for (const line of fs.readFileSync(makefilePath, "utf8").split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_][A-Za-z0-9_.-]*):(?!=)/.exec(line);
    if (match && !match[1].startsWith(".")) {
      target = match[1];
      invoked.set(target, new Set());
    } else if (target && line.startsWith("\t")) {
      for (const selfTest of selfTests) if (commandInvokesSelfTest(line, selfTest)) invoked.get(target).add(selfTest);
    } else if (line && !line.startsWith("#")) {
      target = undefined;
    }
  }
  return invoked;
}

export function discoverSelfTests(testsDirectory) {
  if (!fs.existsSync(testsDirectory)) return [];
  const base = path.dirname(testsDirectory);
  const found = [];
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(absolute);
      else if (/^test-.*\.sh$/.test(entry.name) || /\.test\.mjs$/.test(entry.name)) {
        found.push(path.relative(base, absolute).split(path.sep).join("/"));
      }
    }
  };
  visit(testsDirectory);
  return [...new Set(found)].sort();
}

export function validate(document, { makeTargets, discoveredSelfTests, invokedSelfTests = new Map(), exists = () => true }) {
  const errors = [];
  if (document.schemaVersion !== 1) errors.push("schemaVersion must be 1");
  if (!Array.isArray(document.tiers)) return [...errors, "tiers must be an array"];

  const ids = document.tiers.filter(tier => tier && typeof tier === "object" && !Array.isArray(tier)).map(tier => tier.id);
  if (ids.length !== document.tiers.length) errors.push("every tier must be an object");
  if (new Set(ids).size !== ids.length) errors.push("tier ids must be unique");
  const missing = [...expectedTiers].filter(id => !ids.includes(id)).sort();
  const extra = ids.filter(id => !expectedTiers.has(id)).sort();
  if (missing.length || extra.length) errors.push(`tier set mismatch; missing=${JSON.stringify(missing)}, extra=${JSON.stringify(extra)}`);

  const requiredFields = ["id", "timeoutSeconds", "cadence", "network", "required"];
  for (const tier of document.tiers) {
    if (!tier || typeof tier !== "object" || Array.isArray(tier)) continue;
    const absent = requiredFields.filter(field => !(field in tier));
    if (absent.length) {
      errors.push(`${tier.id}: missing fields ${JSON.stringify(absent.sort())}`);
      continue;
    }
    if (!Number.isInteger(tier.timeoutSeconds) || tier.timeoutSeconds <= 0) errors.push(`${tier.id}: timeoutSeconds must be a positive integer`);
    else if (tier.timeoutSeconds > 3600) errors.push(`${tier.id}: timeoutSeconds exceeds the one-hour policy`);
    if (!networkModes.has(tier.network)) errors.push(`${tier.id}: unknown network mode ${JSON.stringify(tier.network)}`);
    if (typeof tier.required !== "boolean") errors.push(`${tier.id}: required must be boolean`);
    if (typeof tier.cadence !== "string" || !tier.cadence) errors.push(`${tier.id}: cadence must be a nonempty string`);
    if (tier.makeTarget !== undefined && (typeof tier.makeTarget !== "string" || !tier.makeTarget)) errors.push(`${tier.id}: makeTarget must be a nonempty string`);
    else if (tier.makeTarget && !makeTargets.has(tier.makeTarget)) errors.push(`${tier.id}: makeTarget ${JSON.stringify(tier.makeTarget)} is not a Makefile target`);
    if (tier.workflow !== undefined && (typeof tier.workflow !== "string" || !tier.workflow)) errors.push(`${tier.id}: workflow must be a nonempty string`);
    else if (tier.workflow && !exists(tier.workflow)) errors.push(`${tier.id}: workflow ${JSON.stringify(tier.workflow)} does not exist`);
  }

  const flake = document.flakePolicy ?? {};
  if (flake.automaticRetries !== 0) errors.push("automaticRetries must remain zero");
  if (flake.diagnosticReruns !== 1) errors.push("exactly one visible diagnostic rerun is allowed");
  if (JSON.stringify([...(flake.quarantineRequires ?? [])].sort()) !== JSON.stringify(["deadline", "evidence", "owner", "ticket"])) {
    errors.push("quarantineRequires must name owner, ticket, evidence, and deadline");
  }
  const requiredArtifacts = new Set(document.artifactContract?.requiredOnFailure ?? []);
  if (!requiredArtifacts.has("manifest.json") || !requiredArtifacts.has("verifier.log")) errors.push("failure artifacts must include manifest.json and verifier.log");

  if (!Array.isArray(document.selfTests)) return [...errors, "selfTests must be an array"];
  const owned = new Map();
  for (const entry of document.selfTests) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) { errors.push("selfTests entries must be objects"); continue; }
    const absent = ["path", "makeTarget", "tier"].filter(field => !(field in entry));
    if (absent.length) { errors.push(`selfTest ${entry.path ?? "?"}: missing fields ${JSON.stringify(absent.sort())}`); continue; }
    if (typeof entry.path !== "string" || !entry.path) errors.push("selfTest path must be a nonempty string");
    if (typeof entry.makeTarget !== "string" || !entry.makeTarget) errors.push(`selfTest ${entry.path || "?"}: makeTarget must be a nonempty string`);
    else if (!makeTargets.has(entry.makeTarget)) errors.push(`selfTest ${entry.path}: makeTarget ${JSON.stringify(entry.makeTarget)} is not a Makefile target`);
    if (typeof entry.tier !== "string" || !ids.includes(entry.tier)) errors.push(`selfTest ${entry.path}: tier ${JSON.stringify(entry.tier)} is unknown`);
    if (entry.path && !exists(entry.path)) errors.push(`selfTest ${entry.path}: file does not exist`);
    if (entry.path && invokedSelfTests.has(entry.makeTarget) && !invokedSelfTests.get(entry.makeTarget).has(entry.path)) {
      errors.push(`selfTest ${entry.path}: makeTarget ${JSON.stringify(entry.makeTarget)} does not invoke it`);
    }
    if (owned.has(entry.path)) errors.push(`selfTest ${entry.path}: duplicate ownership (also owned by ${JSON.stringify(owned.get(entry.path))})`);
    else owned.set(entry.path, entry.makeTarget);
  }
  for (const found of discoveredSelfTests) if (!owned.has(found)) errors.push(`unmapped self-test ${found}: add it to selfTests with an owning makeTarget`);
  return errors;
}

export function main(argumentsArray = process.argv.slice(2)) {
  if (argumentsArray.length > 1) { console.error("usage: validate-test-tiers.mjs [config-path]"); return 1; }
  const config = path.resolve(argumentsArray[0] ?? path.join(root, "Tests/Support/test-tiers.json"));
  try {
    const document = JSON.parse(fs.readFileSync(config, "utf8"));
    const errors = validate(document, {
      makeTargets: parseMakeTargets(path.join(root, "Makefile")),
      discoveredSelfTests: discoverSelfTests(path.join(root, "Tests")),
      invokedSelfTests: discoverTargetSelfTests(path.join(root, "Makefile"), document.selfTests.map(entry => entry.path)),
      exists: relative => fs.existsSync(path.join(root, relative)),
    });
    if (errors.length) { for (const error of errors) console.error(`test-tier configuration error: ${error}`); return 1; }
    console.log(`PASS: ${document.tiers.length} test tiers and ${document.selfTests.length} self-tests satisfy the Axoloty testing contract`);
    return 0;
  } catch (error) {
    console.error(`test-tier configuration error: ${error.message}`);
    return 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main();
