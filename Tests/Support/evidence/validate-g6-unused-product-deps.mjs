// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

// Every external- or cross-package product declared anywhere in this
// repository's manifests today, mapped to the Swift module name(s) it
// exposes. Not a general SwiftPM product/module resolver: a product name
// found in a manifest but absent from this table fails the check loudly
// (see unmappedProducts below) rather than being guessed, so a future new
// dependency forces a conscious decision here instead of silently
// bypassing the check.
const PRODUCT_MODULES = Object.freeze({
  Axoloty: ["Axoloty"],
  AxolotyMQTT: ["AxolotyMQTT"],
  AxolotyTooling: ["AxolotyTooling"],
  AxolotyVersion: ["AxolotyVersion"],
  ErrorKit: ["ErrorKit"],
  IkigaJSONCore: ["_JSONCore"],
  Logging: ["Logging"],
  MCP: ["MCP"],
  MQTTNIO: ["MQTTNIO"],
  NIO: ["NIO"],
  NIOConcurrencyHelpers: ["NIOConcurrencyHelpers"],
  NIOCore: ["NIOCore"],
  NIOHTTP1: ["NIOHTTP1"],
  NIOPosix: ["NIOPosix"],
  NIOSSL: ["NIOSSL"],
  NIOTransportServices: ["NIOTransportServices"],
  SwiftCompilerPlugin: ["SwiftCompilerPlugin"],
  SwiftDiagnostics: ["SwiftDiagnostics"],
  SwiftSyntax: ["SwiftSyntax"],
  SwiftSyntaxBuilder: ["SwiftSyntaxBuilder"],
  SwiftSyntaxMacros: ["SwiftSyntaxMacros"],
  SwiftSyntaxMacrosTestSupport: ["SwiftSyntaxMacrosTestSupport"],
});

function packageDumpAt(packageRoot) {
  return JSON.parse(
    execFileSync(
      process.env.SWIFT_EXECUTABLE ?? "swift",
      ["package", "dump-package", "--package-path", packageRoot, "--disable-automatic-resolution"],
      { cwd: packageRoot, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    ),
  );
}

// An import line may carry leading attributes (`@preconcurrency import X`,
// `@_spi(Y) import Z`) -- mirrors RepositoryAuthority.importedModules.
function importedModules(source) {
  const modules = new Set();
  for (const rawLine of source.split("\n")) {
    let line = rawLine.trim();
    while (line.startsWith("@")) {
      const spaceOrParen = line.search(/[\s(]/);
      if (spaceOrParen === -1) break;
      if (line[spaceOrParen] === "(") {
        const close = line.indexOf(")", spaceOrParen);
        if (close === -1) break;
        line = line.slice(close + 1).trim();
      } else {
        line = line.slice(spaceOrParen + 1).trim();
      }
    }
    if (!line.startsWith("import ")) continue;
    const match = line.slice("import ".length).match(/^[A-Za-z_][A-Za-z0-9_]*/);
    if (match) modules.add(match[0]);
  }
  return modules;
}

function swiftFiles(directory) {
  const results = [];
  const stack = [directory];
  while (stack.length) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile() && entry.name.endsWith(".swift")) results.push(full);
    }
  }
  return results;
}

// Validates one SwiftPM manifest: every target's directly-declared `.product`
// dependency must have its resolved module imported by at least one source
// file under that target's path. This only flags over-declaration (declared,
// unused) -- a module reachable only transitively through another declared
// dependency is accepted repository policy and is never flagged here.
function validateManifest(packageRoot, packageLabel) {
  const dump = packageDumpAt(packageRoot);
  const errors = [];
  const unmappedProducts = new Set();

  for (const target of dump.targets ?? []) {
    const productDeps = (target.dependencies ?? [])
      .filter((dep) => Array.isArray(dep.product))
      .map((dep) => dep.product[0]);
    if (productDeps.length === 0) continue;

    // SwiftPM reports an explicit `path` only when the manifest declares
    // one; otherwise it defaults to Tests/<name> or Sources/<name> by
    // target type, and dump-package leaves `path` null rather than
    // resolving that default itself.
    const defaultDirectory = target.type === "test" ? "Tests" : "Sources";
    const targetDirectory = path.join(packageRoot, target.path ?? path.join(defaultDirectory, target.name));
    const imported = new Set();
    for (const file of swiftFiles(targetDirectory)) {
      for (const module of importedModules(fs.readFileSync(file, "utf8"))) imported.add(module);
    }

    for (const productName of productDeps) {
      const modules = PRODUCT_MODULES[productName];
      if (!modules) {
        unmappedProducts.add(productName);
        continue;
      }
      if (!modules.some((module) => imported.has(module))) {
        errors.push(
          `${packageLabel}:${target.name} declares product "${productName}" but no source imports ${modules.join(" or ")}`,
        );
      }
    }
  }

  for (const productName of unmappedProducts) {
    errors.push(
      `${packageLabel} declares product "${productName}", which is not in PRODUCT_MODULES -- add its module name mapping before this check can validate it`,
    );
  }

  return errors;
}

export function validate(root) {
  const errors = [...validateManifest(root, "root")];
  const appsRoot = path.join(root, "Apps");
  if (fs.existsSync(path.join(appsRoot, "Package.swift"))) {
    errors.push(...validateManifest(appsRoot, "Apps"));
  }
  return { errors };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = path.resolve(process.argv[2] ?? process.cwd());
  const report = validate(root);
  process.stdout.write(`${JSON.stringify({ schemaVersion: 1, ...report, status: report.errors.length ? "failed" : "passed" })}\n`);
  if (report.errors.length) process.exitCode = 1;
}
