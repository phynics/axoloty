// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const modules = [
  ["AxolotyWire", "Packages/AxolotyWire/Sources/AxolotyWire"],
  ["AxolotyProtocol", "Packages/AxolotyProtocol/Sources/AxolotyProtocol"],
];

function fail(message) {
  throw new Error(message);
}

function digest(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function canonicalSources(root, sourceRoot) {
  const directory = path.join(root, sourceRoot);
  if (!fs.statSync(directory).isDirectory()) fail(`missing source root: ${sourceRoot}`);
  const result = [];
  const visit = (current, relative) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      const child = path.posix.join(relative, entry.name);
      if (entry.isDirectory()) visit(absolute, child);
      else if (entry.isFile() && entry.name.endsWith(".swift")) result.push(child);
      else if (entry.isSymbolicLink()) fail(`source root contains a symlink: ${child}`);
    }
  };
  visit(directory, sourceRoot);
  return result.sort();
}

function requireReceiptMetadata(receipt, file) {
  if (!["swiftpm", "esp-idf-cmake"].includes(receipt.buildSystem)) {
    fail(`${file} must identify swiftpm or esp-idf-cmake as its buildSystem`);
  }
  for (const key of ["targetTriple", "compilerIdentity"]) {
    if (typeof receipt[key] !== "string" || receipt[key].trim() === "") fail(`${file} requires ${key}`);
  }
  if (typeof receipt.compilerArgumentsDigest !== "string" || !/^[0-9a-f]{64}$/.test(receipt.compilerArgumentsDigest)) {
    fail(`${file} requires a SHA-256 compilerArgumentsDigest`);
  }
}

function loadReceipt(file) {
  let receipt;
  try {
    receipt = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`unable to decode source receipt ${file}: ${error.message}`);
  }
  if (receipt.schemaVersion !== 1) fail(`unsupported source receipt schema in ${file}`);
  if (!Array.isArray(receipt.modules)) fail(`source receipt modules must be an array: ${file}`);
  requireReceiptMetadata(receipt, file);
  return receipt;
}

function moduleReceipt(receipt, name, file) {
  const matches = receipt.modules.filter((entry) => entry.module === name);
  if (matches.length !== 1) fail(`${file} must contain exactly one ${name} receipt`);
  const entry = matches[0];
  if (!Array.isArray(entry.sources) || entry.sources.length === 0) fail(`${name} source receipt is empty`);
  const seen = new Set();
  for (const source of entry.sources) {
    if (typeof source.path !== "string" || typeof source.sha256 !== "string") fail(`${name} source receipt has an invalid source entry`);
    if (path.isAbsolute(source.path) || source.path.split("/").includes("..")) fail(`${name} source receipt contains a non-canonical path`);
    if (seen.has(source.path)) fail(`${name} source receipt contains a duplicate path`);
    seen.add(source.path);
  }
  return new Map(entry.sources.map((source) => [source.path, source.sha256]));
}

export function validate({ root, host, embedded }) {
  const hostReceipt = loadReceipt(host);
  const embeddedReceipt = loadReceipt(embedded);
  const summaries = [];
  for (const [name, sourceRoot] of modules) {
    const expected = canonicalSources(root, sourceRoot);
    const hostSources = moduleReceipt(hostReceipt, name, host);
    const embeddedSources = moduleReceipt(embeddedReceipt, name, embedded);
    if (JSON.stringify([...hostSources.keys()].sort()) !== JSON.stringify([...embeddedSources.keys()].sort())) {
      fail(`${name} host and embedded source sets differ`);
    }
    if (JSON.stringify([...hostSources.keys()].sort()) !== JSON.stringify(expected)) {
      fail(`${name} compiler receipt does not cover the canonical production source set`);
    }
    for (const source of expected) {
      const actual = digest(path.join(root, source));
      if (hostSources.get(source) !== actual || embeddedSources.get(source) !== actual) {
        fail(`${name} compiler receipt hash does not match ${source}`);
      }
    }
    summaries.push({ module: name, sourceCount: expected.length, sourceRoot });
  }
  return {
    schemaVersion: 1,
    status: "passed",
    sourceIdentity: "compiler-input-receipts",
    receipts: {
      host: { buildSystem: hostReceipt.buildSystem, targetTriple: hostReceipt.targetTriple, compilerIdentity: hostReceipt.compilerIdentity },
      embedded: { buildSystem: embeddedReceipt.buildSystem, targetTriple: embeddedReceipt.targetTriple, compilerIdentity: embeddedReceipt.compilerIdentity },
    },
    modules: summaries,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [root, host, embedded] = process.argv.slice(2);
  if (!root || !host || !embedded) {
    console.error("usage: validate-g6-source-receipts.mjs <root> <host.json> <embedded.json>");
    process.exit(64);
  }
  try {
    console.log(JSON.stringify(validate({ root, host, embedded })));
  } catch (error) {
    console.error(`G6 SOURCE RECEIPT FAIL: ${error.message}`);
    process.exit(1);
  }
}
