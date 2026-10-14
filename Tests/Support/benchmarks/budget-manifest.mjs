// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";

const integer = value => Number.isInteger(value) && typeof value !== "boolean";
const requiredFingerprint = ["boardModel", "boardRevision", "cpuFrequencyMhz", "swiftCompilerVersion", "idfSwiftVersion", "espIdfVersion", "gccBinutilsVersion", "optimizationMode", "compilerFlags", "containerImageDigest", "corpusVersion", "corpusHash", "moduleApiVersion", "gitCommit", "gitClean", "benchmarkHarnessVersion", "freeRtosTickRate", "taskStackSizes"];
const requiredResources = ["freeHeap", "minFreeHeap", "largestFreeBlock", "fragmentation", "stackHighWater", "data", "bss", "iram", "flashImage"];

function requireKeys(object, keys, prefix, errors) {
  for (const key of keys) if (!(key in object)) errors.push(`${prefix} missing: ${key}`);
}

function checkFingerprint(environment, name, approved, errors) {
  if (!environment.fingerprint || typeof environment.fingerprint !== "object") {
    errors.push(`environments.${name} missing fingerprint object`);
    return;
  }
  if (approved) for (const key of requiredFingerprint) {
    if (typeof environment.fingerprint[key] !== "string" || !environment.fingerprint[key]) {
      errors.push(`environments.${name}.fingerprint.${key} must be a non-empty string when approved (got ${JSON.stringify(environment.fingerprint[key])})`);
    }
  }
}

function checkHost(host, approved, errors) {
  requireKeys(host, ["latency", "binarySize", "dependencyClosure"], "environments.host", errors);
  for (const [operation, entry] of Object.entries(host.latency ?? {})) {
    if (!("status" in entry)) errors.push(`host.latency.${operation} missing: status`);
    for (const field of ["p50ns", "p95ns", "budgetP50ns", "budgetP95ns"]) {
      if (entry[field] != null && !integer(entry[field])) errors.push(`host.latency.${operation}.${field} must be an integer or null`);
      if (approved && entry[field] == null) errors.push(`host.latency.${operation}: ${field} must be non-null when approved`);
    }
    if (approved && entry.status === "pending-baseline") errors.push(`host.latency.${operation}: status is pending-baseline in approved manifest`);
  }
  for (const [consumer, entry] of Object.entries(host.binarySize ?? {})) {
    if (!("status" in entry)) errors.push(`host.binarySize.${consumer} missing: status`);
    for (const field of ["unstrippedBytes", "strippedBytes"]) {
      if (entry[field] != null && !integer(entry[field])) errors.push(`host.binarySize.${consumer}.${field} must be an integer or null`);
      if (approved && entry[field] == null) errors.push(`host.binarySize.${consumer}: ${field} must be non-null when approved`);
    }
    if (approved && entry.status === "pending-baseline") errors.push(`host.binarySize.${consumer}: status is pending-baseline in approved manifest`);
  }
  if (host.dependencyClosure?.AxolotyWireConsumer?.hostDeps?.length) errors.push("host.dependencyClosure.AxolotyWireConsumer.hostDeps must be empty");
}

function checkDevice(device, approved, errors, name = "esp32c6") {
  if (!approved && device.implementation == null) errors.push(`environments.${name} missing: implementation`);
  if (approved && device.implementation !== "embedded-swift") errors.push(`environments.${name}.implementation must be 'embedded-swift' when approved`);
  if (approved && (!device.sourceRun || typeof device.sourceRun !== "string")) errors.push(`environments.${name}.sourceRun must be a non-empty string when approved`);
  requireKeys(device, ["latency", "resources", "sizeLimits"], `environments.${name}`, errors);
  const allocation = device.hotPathAllocations;
  if (!allocation && !("allocationBudget" in device)) errors.push(`environments.${name} missing: hotPathAllocations (or allocationBudget)`);
  if (allocation && (!integer(allocation.budget) || allocation.budget !== 0)) errors.push(`environments.${name}.hotPathAllocations.budget must be exactly 0 (exact-zero)`);
  if (approved && allocation && allocation.measured !== 0) errors.push(`environments.${name}.hotPathAllocations.measured must be exactly 0 when approved`);
  for (const [operation, entry] of Object.entries(device.latency ?? {})) {
    for (const field of ["measuredP50us", "measuredP95us", "budgetP50us", "budgetP95us"]) if (entry[field] != null && !integer(entry[field])) errors.push(`${name}.latency.${operation}.${field} must be an integer or null`);
    if (approved) for (const field of ["measuredP50us", "measuredP95us", "budgetP50us", "budgetP95us"]) if (entry[field] == null) errors.push(`${name}.latency.${operation}.${field} must be non-null when approved`);
    for (const percentile of ["50", "95"]) if (entry[`measuredP${percentile}us`] != null && entry[`budgetP${percentile}us`] != null && entry[`budgetP${percentile}us`] <= entry[`measuredP${percentile}us`]) errors.push(`${name}.latency.${operation}: budgetP${percentile}us must be > measuredP${percentile}us`);
  }
  for (const [resource, entry] of Object.entries(device.resources ?? {})) {
    if (!("measured" in entry)) errors.push(`${name}.resources.${resource} missing: measured`);
    if (entry.measured != null && !integer(entry.measured)) errors.push(`${name}.resources.${resource}.measured must be an integer or null`);
    if (!("budgetMin" in entry) && !("budgetMax" in entry)) errors.push(`${name}.resources.${resource} missing: budgetMin or budgetMax`);
    if (entry.budgetMin != null && !integer(entry.budgetMin)) errors.push(`${name}.resources.${resource}.budgetMin must be an integer or null`);
    if (entry.budgetMax != null && !integer(entry.budgetMax)) errors.push(`${name}.resources.${resource}.budgetMax must be an integer or null`);
    if (approved && entry.measured == null) errors.push(`${name}.resources.${resource}.measured must be non-null when approved`);
    if (entry.budgetMin != null && integer(entry.measured) && entry.budgetMin >= entry.measured) errors.push(`${name}.resources.${resource}: budgetMin must be < measured`);
    if (entry.budgetMax != null && integer(entry.measured) && entry.budgetMax <= entry.measured) errors.push(`${name}.resources.${resource}: budgetMax must be > measured`);
  }
  if (approved) for (const resource of requiredResources) if (!(resource in (device.resources ?? {}))) errors.push(`${name}.resources missing mandatory metric when approved: ${resource}`);
  if (approved && device.resources?.sustainedRate?.capacityHeadroomMsgPerS < 125) errors.push(`${name}.resources.sustainedRate.capacityHeadroomMsgPerS must be >= 125 when approved`);
  const flash = device.resources?.flashImage;
  if (flash?.partitionLimitBytes != null && integer(flash.budgetMax) && integer(flash.partitionLimitBytes) && flash.budgetMax >= flash.partitionLimitBytes) errors.push(`${name}.resources.flashImage: budgetMax (${flash.budgetMax}) must be < partitionLimitBytes (${flash.partitionLimitBytes})`);
  for (const [limit, entry] of Object.entries(device.sizeLimits ?? {})) {
    if (!integer(entry.limit)) errors.push(`${name}.sizeLimits.${limit}.limit must be an integer`);
    if (entry.overLimitRejected !== true) errors.push(`${name}.sizeLimits.${limit}: overLimitRejected must be true`);
  }
}

export function validateBudget(manifest) {
  const errors = [];
  for (const key of ["version", "corpusVersion", "moduleApiVersion", "approvalStatus", "noisePolicy", "regressionPolicy", "environments", "historicalEvidence", "phase4EntryEvidenceGates", "phase4CompletionGates"]) if (!(key in manifest)) errors.push(`missing top-level key: ${key}`);
  for (const key of ["version", "corpusVersion"]) if (key in manifest && !integer(manifest[key])) errors.push(`${key} must be an integer`);
  if (typeof manifest.moduleApiVersion !== "string") errors.push("moduleApiVersion must be a string");
  if (!["provisional", "approved"].includes(manifest.approvalStatus)) errors.push(`approvalStatus must be 'provisional' or 'approved', got ${JSON.stringify(manifest.approvalStatus)}`);
  const noise = manifest.noisePolicy ?? {};
  requireKeys(noise, ["relativeMAD", "allocationVariance", "runs", "samplesPerRun"], "noisePolicy", errors);
  if (noise.allocationVariance !== "exact-zero") errors.push("noisePolicy.allocationVariance must be 'exact-zero'");
  if (noise.runs != null && !integer(noise.runs)) errors.push("noisePolicy.runs must be an integer");
  if (noise.samplesPerRun != null && !integer(noise.samplesPerRun)) errors.push("noisePolicy.samplesPerRun must be an integer");
  const regression = manifest.regressionPolicy ?? {};
  requireKeys(regression, ["matchingFingerprintOnly", "noisyRunsFailCollection", "budgetIncreasesRequireEvidence", "failedBudgetsOpenFinding", "zeroAllocationHotPaths"], "regressionPolicy", errors);
  if (regression.zeroAllocationHotPaths !== "exact-zero") errors.push("regressionPolicy.zeroAllocationHotPaths must be 'exact-zero'");
  const evidence = manifest.historicalEvidence?.["esp32c6-c-surrogate"];
  if (!evidence) errors.push("historicalEvidence missing: esp32c6-c-surrogate");
  else { if (evidence.approvalEligible === true) errors.push("historicalEvidence.esp32c6-c-surrogate.approvalEligible must be false (C surrogate is never approval-eligible)"); if (typeof evidence.supersededBy !== "string" || !evidence.supersededBy) errors.push("historicalEvidence.esp32c6-c-surrogate.supersededBy must be a non-empty string"); if (!evidence.description) errors.push("historicalEvidence.esp32c6-c-surrogate.description must be non-empty"); }
  for (const [name, entry] of Object.entries(manifest.historicalEvidence ?? {})) if (entry?.approvalEligible === true) errors.push(`historicalEvidence.${name}.approvalEligible must be false`);
  const approved = manifest.approvalStatus === "approved";
  const host = manifest.environments?.host;
  if (!host) errors.push("environments missing: host");
  else { requireKeys(host, ["compiler", "optimization"], "environments.host", errors); checkFingerprint(host, "host", approved, errors); }
  checkHost(host ?? {}, approved, errors);
  const deviceNames = Object.keys(manifest.environments ?? {}).filter(name => name !== "host" && name.startsWith("esp32c6"));
  if (deviceNames.length === 0) errors.push("environments missing: an esp32c6 device profile");
  for (const name of deviceNames) {
    const environment = manifest.environments[name];
    requireKeys(environment, ["compiler", "optimization"], `environments.${name}`, errors);
    checkFingerprint(environment, name, approved, errors);
    checkDevice(environment, approved, errors, name);
  }
  for (const [name, minimum] of [["phase4EntryEvidenceGates", 5], ["phase4CompletionGates", 4]]) {
    if (!Array.isArray(manifest[name]) || manifest[name].length < minimum) errors.push(`${name} must have at least ${minimum} gates, got ${manifest[name]?.length ?? 0}`);
    for (const gate of manifest[name] ?? []) {
      for (const field of ["id", "description", "threshold", "thresholdType"]) if (!(field in gate)) errors.push(`${name}: gate missing ${field}`);
      if (gate.id != null && (typeof gate.id !== "string" || !gate.id)) errors.push(`${name}: gate id must be a non-empty string`);
      if (gate.thresholdType != null && typeof gate.thresholdType !== "string") errors.push(`${name}.${gate.id}: thresholdType must be a string`);
    }
  }
  return errors;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const errors = validateBudget(manifest);
  if (errors.length) { errors.forEach(error => console.error(`  ${error}`)); process.exit(1); }
  console.log("BUDGET MANIFEST OK");
}
