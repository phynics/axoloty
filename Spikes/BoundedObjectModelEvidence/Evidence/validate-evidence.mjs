// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";

const [schemaPath, evidencePath] = process.argv.slice(2);
if (!schemaPath || !evidencePath) {
  console.error("usage: validate-evidence.mjs SCHEMA EVIDENCE");
  process.exit(2);
}

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const evidence = JSON.parse(fs.readFileSync(evidencePath, "utf8"));

function equal(left, right) { return JSON.stringify(left) === JSON.stringify(right); }
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

function validateHostMeasurements(report) {
  if (report?.evidenceKind !== "host") return [];
  const errors = [];
  if (!Array.isArray(report.layouts) || !Array.isArray(report.operations) || !Array.isArray(report.allocations)) return errors;
  const points = [1, 16, 64];
  const exact = (values, expected, label) => {
    if (values.length !== expected.length || new Set(values).size !== values.length || !expected.every(value => values.includes(value))) {
      errors.push(`${label}: expected each measurement point exactly once`);
    }
  };
  exact(report.layouts.map(layout => `${layout.axis}:${layout.measurementPoint}`), points.flatMap(point => [`object:${point}`, `envelope:${point}`]), "$evidence.layouts");
  exact(report.operations.map(operation => operation.measurementPoint), points, "$evidence.operations");
  exact(report.allocations.map(allocation => allocation.measurementPoint), points, "$evidence.allocations");
  for (const [index, layout] of report.layouts.entries()) {
    const path = `$evidence.layouts[${index}]`;
    if (layout.axis === "object") {
      if (layout.byteCapacity !== layout.measurementPoint || layout.fieldCapacity !== layout.measurementPoint) errors.push(`${path}: object capacities must match its measurement point`);
    } else if (layout.axis === "envelope") {
      if (layout.nameCapacity !== layout.measurementPoint || layout.externalIDCapacity !== layout.measurementPoint) errors.push(`${path}: envelope capacities must match its measurement point`);
    }
  }
  for (const [index, record] of report.operations.entries()) {
    const path = `$evidence.operations[${index}]`;
    for (const field of ["byteCapacity", "fieldCapacity", "nameCapacity", "externalIDCapacity"]) {
      if (record[field] !== record.measurementPoint) errors.push(`${path}.${field}: must match measurementPoint`);
    }
  }
  for (const [index, record] of report.allocations.entries()) {
    const path = `$evidence.allocations[${index}]`;
    for (const field of ["byteCapacity", "fieldCapacity", "nameCapacity", "externalIDCapacity"]) {
      if (record[field] !== record.measurementPoint) errors.push(`${path}.${field}: must match measurementPoint`);
    }
  }
  if (!Array.isArray(report.compilation?.releaseSections)) return errors;
  if (!report.compilation.releaseSections.some(section => section.name === ".text" || section.name === "text")) {
    errors.push("$evidence.compilation.releaseSections: missing text section");
  }
  return errors;
}

function validateEmbeddedEvidence(report) {
  if (report?.evidenceKind !== "embedded-cross-build") return [];
  const errors = [];
  if (!Array.isArray(report.sections) || !report.sections.some(section => section?.name === ".text" || section?.name === "text")) {
    errors.push("$evidence.sections: missing text section");
  }
  if (report.toolchain && !/Swift version|Apple Swift version/.test(report.toolchain)) {
    errors.push("$evidence.toolchain: expected the exact Swift version line");
  }
  return errors;
}

const errors = [...validate(evidence, schema, "$evidence"), ...validateHostMeasurements(evidence), ...validateEmbeddedEvidence(evidence)];
if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`PASS evidence-schema ${evidencePath}`);
