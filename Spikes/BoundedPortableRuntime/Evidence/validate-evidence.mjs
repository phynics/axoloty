// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import {fileURLToPath} from "node:url";

const [schemaPath, evidencePath] = process.argv.slice(2);
if (!schemaPath || !evidencePath) {
  console.error("usage: validate-evidence.mjs SCHEMA EVIDENCE");
  process.exit(2);
}

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const evidence = JSON.parse(fs.readFileSync(evidencePath, "utf8"));

function equal(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function resolve(reference) {
  if (!reference.startsWith("#/")) throw new Error(`unsupported reference: ${reference}`);
  return reference.slice(2).split("/").reduce((value, key) => value[key], schema);
}

function validate(value, rule, path) {
  if (rule.$ref) return validate(value, resolve(rule.$ref), path);
  if (rule.oneOf) {
    const matches = rule.oneOf.filter(candidate => validate(value, candidate, path).length === 0);
    return matches.length === 1 ? [] : [`${path}: expected exactly one schema match, got ${matches.length}`];
  }
  const errors = [];
  if (Object.hasOwn(rule, "const") && !equal(value, rule.const)) errors.push(`${path}: const mismatch`);
  if (rule.enum && !rule.enum.some(candidate => equal(candidate, value))) errors.push(`${path}: value is not allowed`);
  if (rule.type === "object" && (typeof value !== "object" || value === null || Array.isArray(value))) return [`${path}: expected object`];
  if (rule.type === "array" && !Array.isArray(value)) return [`${path}: expected array`];
  if (rule.type === "string" && typeof value !== "string") return [`${path}: expected string`];
  if (rule.type === "integer" && !Number.isInteger(value)) return [`${path}: expected integer`];
  if (rule.type === "number" && typeof value !== "number") return [`${path}: expected number`];
  if (rule.type === "boolean" && typeof value !== "boolean") return [`${path}: expected boolean`];
  if (typeof value === "string") {
    if (rule.minLength !== undefined && value.length < rule.minLength) errors.push(`${path}: string is too short`);
    if (rule.pattern && !(new RegExp(rule.pattern).test(value))) errors.push(`${path}: pattern mismatch`);
  }
  if (typeof value === "number" && rule.minimum !== undefined && value < rule.minimum) errors.push(`${path}: below minimum`);
  if (Array.isArray(value)) {
    if (rule.minItems !== undefined && value.length < rule.minItems) errors.push(`${path}: too few items`);
    if (rule.maxItems !== undefined && value.length > rule.maxItems) errors.push(`${path}: too many items`);
    if (rule.items) value.forEach((item, index) => errors.push(...validate(item, rule.items, `${path}[${index}]`)));
  }
  if (rule.type === "object" && typeof value === "object" && value !== null && !Array.isArray(value)) {
    for (const key of rule.required ?? []) if (!Object.hasOwn(value, key)) errors.push(`${path}.${key}: missing`);
    for (const [key, item] of Object.entries(value)) {
      if (rule.properties?.[key]) errors.push(...validate(item, rule.properties[key], `${path}.${key}`));
      else if (rule.additionalProperties === false) errors.push(`${path}.${key}: additional property`);
    }
  }
  return errors;
}

function validateHardwareEvidence(report) {
  if (report?.evidenceKind !== "hardware" || !Array.isArray(report.configurations)) return [];
  const errors = [];
  const expectedCapacities = [1, 4, 16, 64];
  const capacities = report.configurations.map(configuration => configuration?.capacity);
  if (!equal(capacities, expectedCapacities)) {
    errors.push(`$evidence.configurations: capacities must be ${expectedCapacities.join(",")}`);
  }
  const budgetManifestPath = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../../../Benchmarks/Baselines/budget-manifest.json",
  );
  const expectedFingerprint = crypto.createHash("sha256").update(fs.readFileSync(budgetManifestPath)).digest("hex");
  if (report.budget?.manifestSha256 !== expectedFingerprint) {
    errors.push("$evidence.budget.manifestSha256: does not match the repository budget manifest");
  }
  for (const [configurationIndex, configuration] of report.configurations.entries()) {
    if (typeof configuration !== "object" || configuration === null) continue;
    const capacity = configuration.capacity;
    if (configuration.crossBuild?.capacity !== capacity) {
      errors.push(`$evidence.configurations[${configurationIndex}].crossBuild.capacity: must match configuration capacity`);
    }
    if (!Array.isArray(configuration.runs)) continue;
    const runNumbers = configuration.runs.map(run => run?.runNumber);
    if (!equal(runNumbers, [1, 2])) {
      errors.push(`$evidence.configurations[${configurationIndex}].runs: run numbers must be 1,2`);
    }
    for (const [runIndex, run] of configuration.runs.entries()) {
      if (typeof run !== "object" || run === null) continue;
      const path = `$evidence.configurations[${configurationIndex}].runs[${runIndex}]`;
      if (run.capacity !== capacity) errors.push(`${path}.capacity: must match configuration capacity`);
      if (String(run.boardRevision) !== report.board?.revision) errors.push(`${path}.boardRevision: must match board revision`);
      if (run.flashBytes !== report.board?.flashBytes) errors.push(`${path}.flashBytes: must match board flash`);
      if (run.initializationHeapBefore !== run.initializationHeapAfter) errors.push(`${path}: initialization heap changed`);
      if (run.steadyStateHeapBefore !== run.steadyStateHeapAfter) errors.push(`${path}: steady-state heap changed`);
      if (run.mainStackHighWater < report.budget?.stackReserveBytes) errors.push(`${path}.mainStackHighWater: below stack reserve budget`);
      if (run.mainStackHighWater > run.mainStackSize) errors.push(`${path}.mainStackHighWater: exceeds configured stack size`);
      if (run.relativeMAD > report.budget?.relativeMAD) errors.push(`${path}.relativeMAD: exceeds budget`);
      if (run.sustainedRatePerSecond < 125) errors.push(`${path}.sustainedRatePerSecond: below required rate`);
      if (configuration.crossBuild?.firmwareBytes > 1_048_576) {
        errors.push(`$evidence.configurations[${configurationIndex}].crossBuild.firmwareBytes: exceeds firmware budget`);
      }
    }
  }
  return errors;
}

const errors = [...validate(evidence, schema, "$evidence"), ...validateHardwareEvidence(evidence)];
if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`PASS evidence-schema ${evidencePath}`);
