// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export function codeMask(text) {
  const masked = [...text];
  let index = 0;
  let blockDepth = 0;
  let quote = null;
  const blank = position => { if (text[position] !== "\n") masked[position] = " "; };
  while (index < text.length) {
    if (blockDepth) {
      if (text.startsWith("/*", index)) { blockDepth++; blank(index++); blank(index++); }
      else if (text.startsWith("*/", index)) { blockDepth--; blank(index++); blank(index++); }
      else blank(index++);
    } else if (quote) {
      if (text[index] === "\\") { blank(index++); if (index < text.length) blank(index++); }
      else if (text[index] === quote) { blank(index++); quote = null; }
      else blank(index++);
    } else if (text.startsWith("//", index)) {
      const end = text.indexOf("\n", index) < 0 ? text.length : text.indexOf("\n", index);
      while (index < end) blank(index++);
    } else if (text.startsWith("/*", index)) {
      blockDepth = 1; blank(index++); blank(index++);
    } else if (text[index] === "#") {
      let hashes = 0;
      while (text[index + hashes] === "#") hashes++;
      const quoteStart = index + hashes;
      if (text[quoteStart] === '"') {
        const delimiter = text.startsWith('"""', quoteStart) ? '"""' : '"';
        const closing = delimiter + "#".repeat(hashes);
        const found = text.indexOf(closing, quoteStart + delimiter.length);
        const end = found < 0 ? text.length : found + closing.length;
        while (index < end) blank(index++);
      } else index++;
    } else if (text[index] === '"' || text[index] === "'") {
      quote = text[index]; blank(index++);
    } else index++;
  }
  return masked.join("");
}

function swiftFiles(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const absolute = path.join(directory, entry.name);
    return entry.isDirectory() ? swiftFiles(absolute) : entry.name.endsWith(".swift") ? [absolute] : [];
  }).sort();
}

export function validateWirePackage(packageDirectory) {
  const errors = [];
  const manifestPath = path.join(packageDirectory, "Package.swift");
  const sourceDirectory = path.join(packageDirectory, "Sources/AxolotyWire");
  if (!fs.existsSync(manifestPath)) return [`error: missing AxolotyWire package manifest: ${manifestPath}`];
  const manifest = fs.readFileSync(manifestPath, "utf8");
  const structure = codeMask(manifest);
  if (/\.package\s*\(/.test(structure)) errors.push("error: AxolotyWire package must not declare package dependencies");
  const blocks = [];
  for (const match of structure.matchAll(/\.target\s*\(/g)) {
    const start = structure.indexOf("(", match.index);
    let depth = 0;
    for (let index = start; index < structure.length; index++) {
      if (structure[index] === "(") depth++;
      else if (structure[index] === ")" && --depth === 0) { blocks.push(manifest.slice(match.index, index + 1)); break; }
    }
  }
  const target = blocks.find(block => /\bname\s*:\s*"AxolotyWire"/.test(block));
  if (!target) errors.push("error: missing AxolotyWire target");
  else {
    const targetPath = /\bpath\s*:\s*"([^"]+)"/.exec(target)?.[1];
    if (targetPath !== "Sources/AxolotyWire") errors.push("error: AxolotyWire must declare path: Sources/AxolotyWire");
    else if (/\bdependencies\s*:/.test(codeMask(target))) errors.push("error: AxolotyWire target must not declare runtime dependencies");
  }
  if (!fs.existsSync(sourceDirectory)) errors.push(`error: missing AxolotyWire source directory: ${sourceDirectory}`);
  const importPattern = /^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n]*\))?|public|internal|package|private)\s+)*import\s+([A-Za-z_][A-Za-z0-9_]*)/gm;
  for (const source of swiftFiles(sourceDirectory)) for (const match of codeMask(fs.readFileSync(source, "utf8")).matchAll(importPattern)) {
    if (match[1] !== "Swift") errors.push(`error: AxolotyWire must not import ${match[1]}: ${source}`);
  }
  return errors;
}

export function main(args = process.argv.slice(2)) {
  const packageDirectory = args[0] ?? "Packages/AxolotyWire";
  const errors = validateWirePackage(packageDirectory);
  if (errors.length) { console.error(errors.join("\n")); return 1; }
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main();
