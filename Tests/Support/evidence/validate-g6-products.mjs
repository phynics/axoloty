// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const EXPECTED = Object.freeze({
  libraries: [
    "Axoloty",
    "AxolotyWire",
    "AxolotyProtocol",
    "AxolotyObjectModel",
    "AxolotyCoatyModels",
    "AxolotyMQTT",
    "AxolotyIoRouting",
    "AxolotySensorThingsModel",
    "AxolotySensorThings",
    "AxolotyStaticRuntime",
  ],
  executables: ["axoloty-tool", "ax", "axoloty-inspect", "axoloty-mcp"],
});

function sorted(values) {
  return [...values].sort();
}

function sameSet(actual, expected) {
  return JSON.stringify(sorted(actual)) === JSON.stringify(sorted(expected));
}

function packageDump(root) {
  try {
    const output = execFileSync(
      process.env.SWIFT_EXECUTABLE ?? "swift",
      ["package", "dump-package", "--disable-automatic-resolution"],
      { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    return JSON.parse(output);
  } catch {
    return null;
  }
}

function packageDumpAt(packageRoot) {
  try {
    const output = execFileSync(
      process.env.SWIFT_EXECUTABLE ?? "swift",
      ["package", "dump-package", "--package-path", packageRoot, "--disable-automatic-resolution"],
      { cwd: packageRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    return JSON.parse(output);
  } catch {
    return null;
  }
}

function typeOfProduct(product) {
  const type = product.type;
  if (typeof type === "string") return type.toLowerCase();
  if (type && typeof type === "object") {
    if (Object.hasOwn(type, "library")) return "library";
    if (Object.hasOwn(type, "executable")) return "executable";
  }
  return "unknown";
}

function parseFallbackManifest(root) {
  const source = fs.readFileSync(path.join(root, "Package.swift"), "utf8");
  const libraries = [...source.matchAll(/\.library\(\s*name:\s*"([^"]+)"/g)].map((m) => m[1]);
  const executables = [...source.matchAll(/\.executable\(\s*name:\s*"([^"]+)"/g)].map((m) => m[1]);
  return { libraries, executables, source: "Package.swift" };
}

function examplesInventory(root) {
  const examplesRoot = path.join(root, "Examples");
  if (!fs.existsSync(examplesRoot)) return null;
  const manifest = path.join(examplesRoot, "Package.swift");
  if (!fs.existsSync(manifest)) return { executables: [], source: "missing Examples/Package.swift" };
  const dump = packageDumpAt(examplesRoot);
  if (dump) {
    return {
      executables: (dump.products ?? []).filter(product => typeOfProduct(product) === "executable").map(product => product.name).filter(name => typeof name === "string"),
      source: "swift package dump-package",
    };
  }
  return { executables: [...fs.readFileSync(manifest, "utf8").matchAll(/\.executableTarget\(\s*name:\s*"([^"]+)"/g)].map(match => match[1]), source: "Examples/Package.swift" };
}

export function inventory(root) {
  const dump = packageDump(root);
  if (!dump) return parseFallbackManifest(root);
  const products = Array.isArray(dump.products) ? dump.products : [];
  const result = { libraries: [], executables: [], source: "swift package dump-package" };
  for (const product of products) {
    const name = product?.name;
    if (typeof name !== "string") continue;
    const type = typeOfProduct(product);
    if (type === "library") result.libraries.push(name);
    else if (type === "executable") result.executables.push(name);
  }
  return result;
}

export function validate(root) {
  const actual = inventory(root);
  const errors = [];
  if (!sameSet(actual.libraries, EXPECTED.libraries)) {
    errors.push(`library product set mismatch: expected ${EXPECTED.libraries.join(", ")}; got ${actual.libraries.join(", ")}`);
  }
  if (!sameSet(actual.executables, EXPECTED.executables)) {
    errors.push(`executable product set mismatch: expected ${EXPECTED.executables.join(", ")}; got ${actual.executables.join(", ")}`);
  }
  const examplesRoot = path.join(root, "Examples");
  if (fs.existsSync(examplesRoot) && !fs.statSync(examplesRoot).isDirectory()) {
    errors.push("published Examples path exists but is not a directory");
  }
  const examples = examplesInventory(root);
  const expectedExamples = ["HostRuntimeExample", "WireExample"];
  if (examples && !sameSet(examples.executables, expectedExamples)) {
    errors.push(`example product set mismatch: expected ${expectedExamples.join(", ")}; got ${examples.executables.join(", ")}`);
  }
  return { actual, examples, expected: EXPECTED, expectedExamples, errors };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = path.resolve(process.argv[2] ?? process.cwd());
  const report = validate(root);
  process.stdout.write(`${JSON.stringify({ schemaVersion: 1, ...report, status: report.errors.length ? "failed" : "passed" })}\n`);
  if (report.errors.length) process.exitCode = 1;
}
