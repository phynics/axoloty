// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
// The four canonical categories. A category says what a run needs: "ci" needs
// nothing beyond the container, "wire" needs broker infrastructure, "embedded"
// needs an attached board, and "release" is everything the host can run.
const expectedTiers = new Set(["ci", "wire", "embedded", "release"]);
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

// A SwiftPM `--filter` value is one unanchored regular expression whose
// top-level `|` branches are independent selectors. Swift Testing silently
// ignores a branch that matches nothing -- the run still exits 0 as long as
// some other branch matched -- so a renamed or copied-across-packages name
// decays into a gate that quietly tests less. Expanding the branches lets the
// contract check each one against the source tree.
export function expandFilterAlternatives(filter) {
  if (typeof filter !== "string" || !filter) return [];
  const splitTopLevel = expression => {
    const parts = [];
    let depth = 0;
    let current = "";
    for (const character of expression) {
      if (character === "(") depth += 1;
      else if (character === ")") depth -= 1;
      if (character === "|" && depth === 0) { parts.push(current); current = ""; continue; }
      current += character;
    }
    parts.push(current);
    return parts;
  };
  const expand = expression => splitTopLevel(expression).flatMap(branch => {
    const group = /\(([^()]*)\)/.exec(branch);
    if (!group || !group[1].includes("|")) return [branch];
    return splitTopLevel(group[1]).flatMap(alternative =>
      expand(branch.slice(0, group.index) + alternative + branch.slice(group.index + group[0].length)));
  });
  return expand(filter).map(alternative => alternative.trim()).filter(Boolean);
}

// Names a filter branch may legitimately select: a test module, a suite type
// or its display name, or a source file -- SwiftPM scopes free `@Test`
// functions by their file, so a file name is a real selector.
export function collectFilterSymbols(repositoryRoot, directories = ["Tests", "Tools", "Packages", "Source"]) {
  const names = new Set();
  const addFile = absolute => {
    const name = path.basename(absolute);
    if (name === "Package.swift") {
      for (const match of fs.readFileSync(absolute, "utf8").matchAll(/name:\s*"([A-Za-z_]\w*)"/g)) names.add(match[1]);
      return;
    }
    if (!name.endsWith(".swift")) return;
    names.add(name.slice(0, -".swift".length));
    const contents = fs.readFileSync(absolute, "utf8");
    for (const match of contents.matchAll(/\b(?:struct|class|enum|actor)\s+([A-Za-z_]\w*)/g)) names.add(match[1]);
    for (const match of contents.matchAll(/@Suite\(\s*"([^"]+)"/g)) names.add(match[1]);
  };
  const visit = directory => {
    if (!fs.existsSync(directory)) return;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(absolute);
      else addFile(absolute);
    }
  };
  for (const directory of directories) visit(path.join(repositoryRoot, directory));
  const rootManifest = path.join(repositoryRoot, "Package.swift");
  if (fs.existsSync(rootManifest)) addFile(rootManifest);
  return names;
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

export function validate(document, { makeTargets, discoveredSelfTests, invokedSelfTests = new Map(), exists = () => true, filterSymbols = undefined }) {
  const errors = [];
  if (document.schemaVersion !== 2) errors.push("schemaVersion must be 2");
  if (typeof document.manifestID !== "string" || !document.manifestID) errors.push("manifestID must be a nonempty string");
  if (!Array.isArray(document.nodes)) errors.push("nodes must be an array");
  if (!Array.isArray(document.requiredGates)) errors.push("requiredGates must be an array");
  if ("plans" in document) errors.push("plans were replaced by the four categories; remove the plans section");
  if ("releaseGates" in document) errors.push("releaseGates was replaced by the release category; remove it");
  if ("ciRequiredGates" in document) errors.push("ciRequiredGates was folded into the ci category; remove it");

  const tierByID = new Map((document.tiers ?? []).filter(t => t && typeof t === "object").map(t => [t.id, t]));
  const ciTier = tierByID.get("ci");
  const releaseTier = tierByID.get("release");

  // A category that declares no hardware must not contain a node that needs it:
  // that declaration is how a host decides whether it can run the category.
  for (const tier of tierByID.values()) {
    if (tier.hardware !== "forbidden") continue;
    for (const id of tier.nodes ?? []) {
      const node = (document.nodes ?? []).find(candidate => candidate?.id === id);
      if (node && node.hardware !== "forbidden") {
        errors.push(`${tier.id}: hardware node ${JSON.stringify(id)} cannot belong to a hardware-forbidden category`);
      }
    }
  }

  for (const tier of tierByID.values()) {
    if ("attested" in tier && typeof tier.attested !== "boolean") {
      errors.push(`${tier.id}: attested must be a boolean`);
    }
  }

  // "release" means every test the host can run, so it contains the others --
  // an attested category is declared here even though release proves it from
  // recorded evidence rather than running its nodes.
  if (releaseTier) {
    for (const narrower of ["ci", "wire", "embedded"]) {
      const tier = tierByID.get(narrower);
      if (!tier) continue;
      const missing = (tier.nodes ?? []).filter(id => !(releaseTier.nodes ?? []).includes(id));
      if (missing.length) errors.push(`release omits ${narrower} nodes ${JSON.stringify(missing.sort())}`);
    }
    const orphans = (document.nodes ?? []).map(node => node?.id).filter(id => !(releaseTier.nodes ?? []).includes(id));
    if (orphans.length) errors.push(`nodes outside every category: ${JSON.stringify(orphans.sort())}`);
  }

  // requiredGates is derived from the ci category: exactly those of its nodes
  // the manifest marks required and available both locally and in CI. Nodes
  // that are local-only stay in the category and are filtered when resolving.
  if (ciTier && Array.isArray(document.requiredGates)) {
    const expected = (ciTier.nodes ?? []).filter(id => {
      const node = (document.nodes ?? []).find(candidate => candidate?.id === id);
      return node?.required && node.local && node.ci;
    });
    const gates = JSON.stringify([...document.requiredGates].sort());
    if (gates !== JSON.stringify([...expected].sort())) {
      errors.push("requiredGates must be the required, locally and CI available nodes of the ci category");
    }
  }

  const nodeIds = new Set();
  for (const node of document.nodes ?? []) {
    if (!node || typeof node !== "object" || Array.isArray(node)) { errors.push("every node must be an object"); continue; }
    if (typeof node.id !== "string" || !node.id) errors.push("node id must be a nonempty string");
    if (retiredCanonicalNodes.has(node.id)) errors.push(`${node.id}: retired canonical node must not be declared`);
    const filters = typeof node.filter === "string" ? node.filter.split("|") : [];
    for (const filter of filters) if (retiredCanonicalFilters.has(filter)) errors.push(`${node.id}: retired test filter ${JSON.stringify(filter)} must not be declared`);
    // The declared filter and the argument the command actually passes are two
    // copies of one selector; a gate that drifts between them runs something
    // other than what the manifest documents.
    const commandArguments = Array.isArray(node.command?.arguments) ? node.command.arguments : [];
    const filterArgumentIndex = commandArguments.indexOf("--filter");
    const filterArgument = filterArgumentIndex >= 0 ? commandArguments[filterArgumentIndex + 1] : undefined;
    if ((node.filter ?? undefined) !== filterArgument && (node.filter || filterArgument)) {
      errors.push(`${node.id}: declared filter and the --filter argument disagree`);
    }
    // Every top-level branch of a filter must select something that exists.
    // Swift Testing ignores a branch matching nothing without failing the run.
    if (filterSymbols) {
      for (const alternative of expandFilterAlternatives(node.filter)) {
        // A gate selects a whole module, suite, or file. A hand-listed set of
        // methods silently stops covering tests added to that suite later, and
        // silently keeps naming ones that move away; `make test-one FILTER=`
        // is the supported way to run a single test.
        if (alternative.includes("/")) {
          errors.push(`${node.id}: test filter ${JSON.stringify(alternative)} names individual test methods; select a module, suite, or file instead`);
          continue;
        }
        if (!filterSymbols.has(alternative)) {
          errors.push(`${node.id}: test filter selects ${JSON.stringify(alternative)}, which matches no test module, suite, or file`);
        }
      }
    }
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
  const gateNames = new Set(document.requiredGates ?? []);
  for (const gate of gateNames) if (!nodeIds.has(gate)) errors.push(`required gate ${JSON.stringify(gate)} is not a declared node`);
  for (const node of document.nodes ?? []) {
    if (node?.required && node.local && node.ci && !gateNames.has(node.id)) {
      errors.push(`required node ${JSON.stringify(node.id)} is absent from requiredGates`);
    }
  }
  for (const gate of document.requiredGates ?? []) {
    const node = document.nodes.find(candidate => candidate.id === gate);
    if (!node?.required || !node.local || !node.ci) errors.push(`required gate ${JSON.stringify(gate)} must be required and available locally and in CI`);
  }
  const toolingNode = (document.nodes ?? []).find(node => node?.id === "test-tooling");
  if (!toolingNode?.filter?.split("|").includes("RepositoryAuthorityTests")) {
    errors.push("test-tooling must select RepositoryAuthorityTests");
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
    else if (tier.id !== "release" && tier.timeoutSeconds > 3600) errors.push(`${tier.id}: timeoutSeconds exceeds the one-hour policy`);
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

  const toolCommandIds = new Set(["release-checkpoint", "release-checkpoint-hardware"]);
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
  const canonicalGateNames = new Set(document.requiredGates ?? []);
  const canonicalCommandText = (document.nodes ?? [])
    .filter(node => canonicalGateNames.has(node?.id))
    .map(node => JSON.stringify(node?.command ?? {}))
    .join("\n");
  // Ownership is a manifest fact now, not a Makefile one: a self-test is owned
  // when some node of its declared category actually runs it. That survives any
  // change to the Make entry points, which is what made the old rule fragile.
  const commandTextByTier = new Map((document.tiers ?? []).map(tier => [tier.id,
    (tier.nodes ?? [])
      .map(id => (document.nodes ?? []).find(node => node?.id === id))
      .filter(Boolean)
      .map(node => JSON.stringify(node.command ?? {}))
      .join("\n")]));
  const owned = new Map();
  for (const entry of document.selfTests) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) { errors.push("selfTests entries must be objects"); continue; }
    const absent = ["path", "tier"].filter(field => !(field in entry));
    if (absent.length) { errors.push(`selfTest ${entry.path ?? "?"}: missing fields ${JSON.stringify(absent.sort())}`); continue; }
    if ("makeTarget" in entry) errors.push(`selfTest ${entry.path}: makeTarget was replaced by tier ownership; remove it`);
    if (typeof entry.path !== "string" || !entry.path) errors.push("selfTest path must be a nonempty string");
    if (typeof entry.tier !== "string" || !ids.includes(entry.tier)) errors.push(`selfTest ${entry.path}: tier ${JSON.stringify(entry.tier)} is unknown`);
    if (entry.path && !exists(entry.path)) errors.push(`selfTest ${entry.path}: file does not exist`);
    if (entry.path && !(commandTextByTier.get(entry.tier) ?? "").includes(entry.path)) {
      errors.push(`selfTest ${entry.path}: no node of the ${JSON.stringify(entry.tier)} category runs it`);
    }
    if (entry.path && !canonicalCommandText.includes(entry.path)) {
      errors.push(`selfTest ${entry.path}: no required gate invokes it`);
    }
    if (owned.has(entry.path)) errors.push(`selfTest ${entry.path}: duplicate ownership (also owned by ${JSON.stringify(owned.get(entry.path))})`);
    else owned.set(entry.path, entry.tier);
  }
  for (const found of discoveredSelfTests) if (!owned.has(found)) errors.push(`unmapped self-test ${found}: add it to selfTests with an owning category`);
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
      filterSymbols: collectFilterSymbols(root),
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
