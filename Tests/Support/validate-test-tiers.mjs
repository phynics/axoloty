// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const expectedTiers = new Set(["smoke", "unit", "module", "wire-offline", "wire-live", "support", "manual-macos", "g3-object-model", "g4-runtime", "g5-optional-products", "g6-non-divergence"]);
const networkModes = new Set(["none", "isolated", "isolated-broker", "isolated-containers"]);
const brokerModes = new Set(["none", "local", "isolated"]);
const hardwareModes = new Set(["forbidden", "optional", "required"]);
const isolationModes = new Set(["parallel", "separate-process", "exclusive"]);
const retiredCanonicalNodes = new Set(["integration-tests", "logging-global"]);
const retiredCanonicalFilters = new Set(["MQTTNIOClientTests", "DecentralizedLoggingTest", "LogManagerTests"]);

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
  const pattern = repositoryPath.split("*").map(segment => segment.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[^/]*");
  return new RegExp(`^${pattern}$`).test(selfTestPath);
}

function commandTokens(command) {
  return command.trim().replace(/^[@+-]+/, "").match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) ?? [];
}

function executableIndex(tokens) {
  let index = 0;
  while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[index] ?? "")) index += 1;
  return index;
}

function shellScriptOperand(tokens, interpreterIndex) {
  let index = interpreterIndex + 1;
  while (index < tokens.length) {
    const token = tokens[index];
    if (token === "--") return tokens[index + 1];
    if (!token.startsWith("-") && token !== "+o") return token;
    if (token === "-c" || token === "--command" || /^-[^-]*c/.test(token)) return undefined;
    if (["-o", "+o", "-O", "--init-file", "--rcfile"].includes(token)) index += 1;
    index += 1;
  }
  return undefined;
}

function commandInvokesSelfTest(command, selfTestPath) {
  const tokens = commandTokens(command);
  const invokes = commandTokensToInspect => {
    const executable = executableIndex(commandTokensToInspect);
    const program = commandTokensToInspect[executable] ?? "";
    if (shellTokenMatchesPath(program, selfTestPath) && !program.includes("*")) return true;
    if (program === ".devcontainer/run.sh") return invokes(commandTokensToInspect.slice(executable + 1));
    if (program === "$(call" && /^run_container,/.test(commandTokensToInspect[executable + 1] ?? "")) {
      return invokes(commandTokensToInspect.slice(executable + 2));
    }
    if (["sh", "bash", "dash", "zsh"].includes(program)) {
      const script = shellScriptOperand(commandTokensToInspect, executable) ?? "";
      return !script.includes("*") && shellTokenMatchesPath(script, selfTestPath);
    }
    if (program !== "node") return false;
    const testOption = commandTokensToInspect.indexOf("--test", executable + 1);
    return testOption >= 0 && commandTokensToInspect.slice(testOption + 1).some(token => shellTokenMatchesPath(token, selfTestPath));
  };
  return invokes(tokens);
}

function recursiveMakeTarget(command) {
  const tokens = commandTokens(command);
  let index = executableIndex(tokens);
  if (tokens[index] !== "$(MAKE)") return undefined;
  index += 1;
  while (index < tokens.length) {
    if (tokens[index].startsWith("-")) {
      if (["-C", "-f", "--directory", "--file"].includes(tokens[index])) index += 1;
      index += 1;
    } else if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[index])) {
      index += 1;
    } else {
      return tokens[index];
    }
  }
  return undefined;
}

export function discoverTargetSelfTests(makefilePath, selfTests, tierNodeCommands = new Map()) {
  if (!fs.existsSync(makefilePath)) return new Map();
  const recipes = new Map();
  let target;
  for (const line of fs.readFileSync(makefilePath, "utf8").split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_][A-Za-z0-9_.-]*):(?!=)/.exec(line);
    if (match && !match[1].startsWith(".")) {
      target = match[1];
      recipes.set(target, []);
    } else if (target && line.startsWith("\t")) {
      recipes.get(target).push(line);
    } else if (line && !line.startsWith("#")) {
      target = undefined;
    }
  }

  const direct = new Map();
  const children = new Map();
  for (const [name, commands] of recipes) {
    direct.set(name, new Set());
    children.set(name, new Set());
    for (const command of commands) {
      for (const selfTest of selfTests) if (commandInvokesSelfTest(command, selfTest)) direct.get(name).add(selfTest);
      // A tier alias such as `$(MAKE) test-tier TIER=support` invokes every
      // node command the manifest tier declares; resolve those commands so
      // ownership checks keep holding through the indirection.
      const tierAlias = /^\s*@?\$\(MAKE\)\s+--no-print-directory\s+test-tier\s+TIER="?([A-Za-z0-9_.-]+)"?/.exec(command);
      if (tierAlias) {
        for (const nodeCommand of tierNodeCommands.get(tierAlias[1]) ?? []) {
          for (const selfTest of selfTests) if (commandInvokesSelfTest(nodeCommand, selfTest)) direct.get(name).add(selfTest);
        }
      }
      const child = recursiveMakeTarget(command);
      if (child) children.get(name).add(child);
    }
  }

  const invoked = new Map();
  for (const name of recipes.keys()) {
    const found = new Set();
    const visited = new Set();
    const visit = targetName => {
      if (visited.has(targetName)) return;
      visited.add(targetName);
      for (const selfTest of direct.get(targetName) ?? []) found.add(selfTest);
      for (const child of children.get(targetName) ?? []) visit(child);
    };
    visit(name);
    invoked.set(name, found);
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
  if (document.schemaVersion !== 2) errors.push("schemaVersion must be 2");
  if (typeof document.manifestID !== "string" || !document.manifestID) errors.push("manifestID must be a nonempty string");
  if (!Array.isArray(document.nodes)) errors.push("nodes must be an array");
  if (!document.plans || typeof document.plans !== "object" || Array.isArray(document.plans)) errors.push("plans must be an object");
  if (!Array.isArray(document.requiredGates) || !Array.isArray(document.ciRequiredGates)) errors.push("requiredGates and ciRequiredGates must be arrays");
  if (!Array.isArray(document.releaseGates)) errors.push("releaseGates must be an array");

  // Resolve named-plan inheritance before checking coverage. Keeping this
  // here (and in the Swift planner) makes the checked-in JSON independently
  // auditable by CI and catches omissions before any command executes.
  const resolving = new Set();
  const resolvedPlans = new Map();
  const resolvePlan = name => {
    if (resolvedPlans.has(name)) return resolvedPlans.get(name);
    const plan = document.plans?.[name];
    if (!plan || typeof plan !== "object") {
      errors.push(`plan ${name}: unknown plan`);
      return [];
    }
    if (resolving.has(name)) {
      errors.push(`plan inheritance cycle at ${JSON.stringify(name)}`);
      return [];
    }
    resolving.add(name);
    const parent = plan.inherits ? resolvePlan(plan.inherits) : [];
    const nodes = [...new Set([...parent, ...(Array.isArray(plan.nodes) ? plan.nodes : [])])];
    resolving.delete(name);
    resolvedPlans.set(name, nodes);
    return nodes;
  };
  for (const name of Object.keys(document.plans ?? {})) resolvePlan(name);
  const ordinaryPlanNames = ["verify", "offline"];
  for (const name of ordinaryPlanNames) {
    for (const node of resolvedPlans.get(name) ?? []) {
      const declaration = (document.nodes ?? []).find(candidate => candidate?.id === node);
      if (declaration?.hardware !== "forbidden") {
        errors.push(`plan ${name}: hardware node ${JSON.stringify(node)} is forbidden in ordinary/offline plans`);
      }
    }
  }
  const ordinary = new Set(resolvedPlans.get("checkpoint") ?? []);
  const hardware = new Set(resolvedPlans.get("checkpoint-hardware") ?? []);
  if (document.plans?.["checkpoint-hardware"]?.inherits !== "checkpoint") {
    errors.push("plan checkpoint-hardware must inherit checkpoint");
  }
  for (const node of ordinary) if (!hardware.has(node)) errors.push(`plan checkpoint-hardware omits inherited node ${JSON.stringify(node)}`);
  if (hardware.size <= ordinary.size) errors.push("plan checkpoint-hardware must be a strict superset of checkpoint");

  const nodeIds = new Set();
  for (const node of document.nodes ?? []) {
    if (!node || typeof node !== "object" || Array.isArray(node)) { errors.push("every node must be an object"); continue; }
    if (typeof node.id !== "string" || !node.id) errors.push("node id must be a nonempty string");
    if (retiredCanonicalNodes.has(node.id)) errors.push(`${node.id}: retired canonical node must not be declared`);
    const filters = typeof node.filter === "string" ? node.filter.split("|") : [];
    for (const filter of filters) if (retiredCanonicalFilters.has(filter)) errors.push(`${node.id}: retired test filter ${JSON.stringify(filter)} must not be declared`);
    if (nodeIds.has(node.id)) errors.push(`duplicate node id ${JSON.stringify(node.id)}`);
    nodeIds.add(node.id);
    for (const dependency of node.dependencies ?? []) if (!nodeIds.has(dependency) && !(document.nodes ?? []).some(candidate => candidate?.id === dependency)) errors.push(`${node.id}: unknown dependency ${JSON.stringify(dependency)}`);
    for (const field of ["timeoutSeconds", "expectedDurationSeconds"]) if (!Number.isInteger(node[field]) || node[field] <= 0) errors.push(`${node.id}: ${field} must be a positive integer`);
    if (node.timeoutSeconds > 3600) errors.push(`${node.id}: timeoutSeconds exceeds the one-hour policy`);
    if (!networkModes.has(node.network)) errors.push(`${node.id}: unknown network mode ${JSON.stringify(node.network)}`);
    if (!brokerModes.has(node.broker)) errors.push(`${node.id}: unknown broker mode ${JSON.stringify(node.broker)}`);
    if (!hardwareModes.has(node.hardware)) errors.push(`${node.id}: unknown hardware mode ${JSON.stringify(node.hardware)}`);
    if (!isolationModes.has(node.isolation)) errors.push(`${node.id}: unknown isolation mode ${JSON.stringify(node.isolation)}`);
    if (node.hardware !== "forbidden" && !node.resources?.includes("embedded-device")) errors.push(`${node.id}: hardware nodes must own embedded-device`);
    if (["signal-disposition", "logging-global", "environment", "fixed-port-1883"].some(resource => (node.resources ?? []).includes(resource)) && node.isolation === "parallel") errors.push(`${node.id}: process-global or fixed-port resources cannot use parallel isolation`);
  }
  const gateNames = new Set([...(document.requiredGates ?? []), ...(document.ciRequiredGates ?? [])]);
  for (const gate of gateNames) if (!nodeIds.has(gate)) errors.push(`required gate ${JSON.stringify(gate)} is not a declared node`);
  for (const node of document.nodes ?? []) {
    if (node?.required && node.local && node.ci && !gateNames.has(node.id)) {
      errors.push(`required node ${JSON.stringify(node.id)} is absent from requiredGates`);
    }
  }
  for (const [name, plan] of Object.entries(document.plans ?? {})) {
    if (!Array.isArray(plan?.nodes)) { errors.push(`plan ${name}: nodes must be an array`); continue; }
    if (!Number.isInteger(plan.timeoutSeconds) || plan.timeoutSeconds <= 0) {
      errors.push(`plan ${name}: timeoutSeconds must be a positive integer`);
    } else if (name === "verify" && plan.timeoutSeconds !== 4800) {
      errors.push("plan verify: timeoutSeconds must be 4800 seconds (80 minutes), below the 90-minute CI job deadline");
    }
    for (const node of [...plan.nodes, ...(plan.ciNodes ?? [])]) if (!nodeIds.has(node)) errors.push(`plan ${name}: unknown node ${JSON.stringify(node)}`);
  }
  const makeAliases = {
    "test-wire": "wire-offline",
    "test-unit": "unit",
    "test-module": "module",
    "test-support": "support",
  };
  for (const [target, planName] of Object.entries(makeAliases)) {
    const tier = document.tiers.find(candidate => candidate.makeTarget === target);
    if (!tier) errors.push(`Make target ${target} has no canonical tier`);
    if (target === "test-wire" && document.plans?.[planName]?.nodes?.includes("test-tooling")) errors.push("test-wire must not include tooling tests");
  }
  if (!document.plans?.verify || !Array.isArray(document.plans.verify.nodes)) errors.push("verify plan must exist");
  if ((document.plans?.verify?.nodes ?? []).length || (document.plans?.verify?.ciNodes ?? []).length) {
    errors.push("verify roots must be derived from requiredGates and ciRequiredGates, not duplicated in plans.verify");
  }
  for (const gate of document.requiredGates ?? []) {
    const node = document.nodes.find(candidate => candidate.id === gate);
    if (!node?.required || !node.local || !node.ci) errors.push(`required gate ${JSON.stringify(gate)} must be required and available locally and in CI`);
  }
  for (const gate of document.ciRequiredGates ?? []) {
    const node = document.nodes.find(candidate => candidate.id === gate);
    if (!node?.required || !node.ci) errors.push(`CI required gate ${JSON.stringify(gate)} must be required and CI-available`);
  }
  const toolingNode = (document.nodes ?? []).find(node => node?.id === "test-tooling");
  if (!toolingNode?.filter?.split("|").includes("RepositoryAuthorityTests")) {
    errors.push("test-tooling must select RepositoryAuthorityTests");
  }
  const checkpointRoots = new Set([...ordinary, ...hardware]);
  for (const gate of document.releaseGates ?? []) {
    const tier = (document.tiers ?? []).find(candidate => candidate?.id === gate);
    if (!tier) errors.push(`release gate ${JSON.stringify(gate)} is not a declared tier`);
    else if (!tier.required) errors.push(`release gate ${JSON.stringify(gate)} must reference a required tier`);
  }
  for (const tier of (document.tiers ?? [])) {
    if (tier?.required && !(document.releaseGates ?? []).includes(tier.id)) {
      errors.push(`required tier ${JSON.stringify(tier.id)} is absent from releaseGates`);
    }
  }
  if (checkpointRoots.size) {
    const requiredReleaseTiers = (document.tiers ?? []).filter(tier => tier?.required);
    // wire-live and other peer/oracle tiers are intentionally attestable
    // rather than run inside the checkpoint, so they are exempt from node
    // coverage as long as they appear in releaseGates (checked above).
    const attestableTiers = new Set(["wire-live", "manual-macos"]);
    for (const tier of requiredReleaseTiers) {
      if (tier.nodes.some(node => checkpointRoots.has(node)) || attestableTiers.has(tier.id)) continue;
      errors.push(`required release tier ${JSON.stringify(tier.id)} is not covered by the checkpoint plan and not attestable`);
    }
  }
  if (!document.testOne?.command?.filterFlag || !Number.isInteger(document.testOne?.timeoutSeconds) || document.testOne.timeoutSeconds <= 0) errors.push("testOne must declare a filterFlag and positive timeoutSeconds");

  if (!Array.isArray(document.tiers)) return [...errors, "tiers must be an array"];

  const ids = document.tiers.filter(tier => tier && typeof tier === "object" && !Array.isArray(tier)).map(tier => tier.id);
  if (ids.length !== document.tiers.length) errors.push("every tier must be an object");
  if (new Set(ids).size !== ids.length) errors.push("tier ids must be unique");
  const missing = [...expectedTiers].filter(id => !ids.includes(id)).sort();
  const extra = ids.filter(id => !expectedTiers.has(id)).sort();
  if (missing.length || extra.length) errors.push(`tier set mismatch; missing=${JSON.stringify(missing)}, extra=${JSON.stringify(extra)}`);

  const requiredFields = ["id", "timeoutSeconds", "expectedDurationSeconds", "cadence", "network", "broker", "hardware", "required", "local", "ci", "nodes"];
  for (const tier of document.tiers) {
    if (!tier || typeof tier !== "object" || Array.isArray(tier)) continue;
    const absent = requiredFields.filter(field => !(field in tier));
    if (absent.length) {
      errors.push(`${tier.id}: missing fields ${JSON.stringify(absent.sort())}`);
      continue;
    }
    if (!Number.isInteger(tier.timeoutSeconds) || tier.timeoutSeconds <= 0) errors.push(`${tier.id}: timeoutSeconds must be a positive integer`);
    else if (tier.timeoutSeconds > 3600) errors.push(`${tier.id}: timeoutSeconds exceeds the one-hour policy`);
    if (!Number.isInteger(tier.expectedDurationSeconds) || tier.expectedDurationSeconds <= 0) errors.push(`${tier.id}: expectedDurationSeconds must be a positive integer`);
    if (!networkModes.has(tier.network)) errors.push(`${tier.id}: unknown network mode ${JSON.stringify(tier.network)}`);
    if (!brokerModes.has(tier.broker)) errors.push(`${tier.id}: unknown broker mode ${JSON.stringify(tier.broker)}`);
    if (!hardwareModes.has(tier.hardware)) errors.push(`${tier.id}: unknown hardware mode ${JSON.stringify(tier.hardware)}`);
    if (!isolationModes.has(tier.isolation)) errors.push(`${tier.id}: unknown isolation mode ${JSON.stringify(tier.isolation)}`);
    if (typeof tier.required !== "boolean") errors.push(`${tier.id}: required must be boolean`);
    if (typeof tier.local !== "boolean" || typeof tier.ci !== "boolean") errors.push(`${tier.id}: local and ci must be boolean`);
    if (!Array.isArray(tier.nodes) || tier.nodes.some(node => !nodeIds.has(node))) errors.push(`${tier.id}: nodes must reference declared nodes`);
    if (typeof tier.cadence !== "string" || !tier.cadence) errors.push(`${tier.id}: cadence must be a nonempty string`);
    if (tier.makeTarget !== undefined && tier.makeTarget !== null && (typeof tier.makeTarget !== "string" || !tier.makeTarget)) errors.push(`${tier.id}: makeTarget must be a nonempty string`);
    else if (tier.makeTarget && !makeTargets.has(tier.makeTarget)) errors.push(`${tier.id}: makeTarget ${JSON.stringify(tier.makeTarget)} is not a Makefile target`);
    if (tier.workflow !== undefined && (typeof tier.workflow !== "string" || !tier.workflow)) errors.push(`${tier.id}: workflow must be a nonempty string`);
    else if (tier.workflow && !exists(tier.workflow)) errors.push(`${tier.id}: workflow ${JSON.stringify(tier.workflow)} does not exist`);
  }

  if (document.tiers.some(tier => tier.required && !tier.local && !tier.ci)) errors.push("required tiers must be available locally or in CI");

  const flake = document.flakePolicy ?? {};
  if (flake.automaticRetries !== 0) errors.push("automaticRetries must remain zero");
  if (flake.diagnosticReruns !== 1) errors.push("exactly one visible diagnostic rerun is allowed");
  if (JSON.stringify([...(flake.quarantineRequires ?? [])].sort()) !== JSON.stringify(["deadline", "evidence", "owner", "ticket"])) {
    errors.push("quarantineRequires must name owner, ticket, evidence, and deadline");
  }
  const requiredArtifacts = new Set(document.artifactContract?.requiredOnFailure ?? []);
  if (!requiredArtifacts.has("manifest.json") || !requiredArtifacts.has("verifier.log")) errors.push("failure artifacts must include manifest.json and verifier.log");

  if (!Array.isArray(document.selfTests)) return [...errors, "selfTests must be an array"];

  const toolCommandIds = new Set(["release-checkpoint", "release-checkpoint-hardware", "release-fixture-bundle"]);
  const toolEnv = document.toolContainerEnv;
  if (typeof toolEnv !== "object" || toolEnv === null || Array.isArray(toolEnv)) {
    errors.push("toolContainerEnv must be an object keyed by tool command identifier");
  } else {
    for (const [command, names] of Object.entries(toolEnv)) {
      if (!toolCommandIds.has(command)) errors.push(`toolContainerEnv ${command}: unknown tool command identifier`);
      if (!Array.isArray(names) || names.length === 0) {
        errors.push(`toolContainerEnv ${command}: allowlist must be a nonempty array of env names`);
        continue;
      }
      for (const name of names) {
        if (typeof name !== "string" || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
          errors.push(`toolContainerEnv ${command}: invalid env name ${JSON.stringify(name)}`);
        }
      }
    }
    for (const command of toolCommandIds) {
      if (!Array.isArray(toolEnv[command])) errors.push(`toolContainerEnv: missing allowlist for ${command}`);
    }
  }
  const canonicalGateNames = new Set([...(document.requiredGates ?? []), ...(document.ciRequiredGates ?? [])]);
  const canonicalCommandText = (document.nodes ?? [])
    .filter(node => canonicalGateNames.has(node?.id))
    .map(node => JSON.stringify(node?.command ?? {}))
    .join("\n");
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
    if (entry.path && !canonicalCommandText.includes(entry.path)) {
      errors.push(`selfTest ${entry.path}: canonical verify has no required gate invoking it`);
    }
    if (owned.has(entry.path)) errors.push(`selfTest ${entry.path}: duplicate ownership (also owned by ${JSON.stringify(owned.get(entry.path))})`);
    else owned.set(entry.path, entry.makeTarget);
  }
  for (const found of discoveredSelfTests) if (!owned.has(found)) errors.push(`unmapped self-test ${found}: add it to selfTests with an owning makeTarget`);
  return errors;
}

export function tierNodeCommandsFrom(document) {
  return new Map((document?.tiers ?? [])
    .filter(tier => tier && typeof tier === "object" && Array.isArray(tier.nodes))
    .map(tier => [tier.id, tier.nodes.flatMap(nodeId => {
      const node = (document?.nodes ?? []).find(candidate => candidate?.id === nodeId);
      if (!node?.command) return [];
      return [[node.command.executable ?? "", ...(node.command.arguments ?? [])].join(" ")];
    })]));
}

export function main(argumentsArray = process.argv.slice(2)) {
  if (argumentsArray.length > 1) { console.error("usage: validate-test-tiers.mjs [config-path]"); return 1; }
  const config = path.resolve(argumentsArray[0] ?? path.join(root, "Tests/Support/test-tiers.json"));
  try {
    const document = JSON.parse(fs.readFileSync(config, "utf8"));
    const canonicalConfig = path.join(root, "Tests/Support/test-tiers.json");
    if (config === canonicalConfig) {
      const bundledConfig = path.join(root, "Tools/AxolotyTooling/Resources/test-tiers.json");
      if (!fs.existsSync(bundledConfig) || fs.readFileSync(config, "utf8") !== fs.readFileSync(bundledConfig, "utf8")) {
        console.error("test-tier configuration error: bundled manifest must exactly match Tests/Support/test-tiers.json");
        return 1;
      }
    }
    const configuredSelfTests = Array.isArray(document?.selfTests)
      ? document.selfTests.flatMap(entry => typeof entry?.path === "string" ? [entry.path] : [])
      : [];
    const tierNodeCommands = tierNodeCommandsFrom(document);
    const errors = validate(document, {
      makeTargets: parseMakeTargets(path.join(root, "Makefile")),
      discoveredSelfTests: discoverSelfTests(path.join(root, "Tests")),
      invokedSelfTests: discoverTargetSelfTests(path.join(root, "Makefile"), configuredSelfTests, tierNodeCommands),
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
