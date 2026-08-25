// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
// Decide whether changed repository paths require source coverage evidence.

import fs from "node:fs";
import { fileURLToPath } from "node:url";

export const COVERAGE_AFFECTING = [
  { prefix: "Source/", description: "host product source" },
  { prefix: "Packages/", description: "portable package source" },
  { prefix: "Tools/", description: "first-party tooling source" },
  { prefix: "Tests/", description: "test source and coverage tooling" },
  { prefix: "Embedded/", description: "embedded source compiled by package tests" },
  { prefix: ".devcontainer/", description: "pinned coverage toolchain" },
  { prefix: ".github/actions/setup-container/", description: "coverage container setup" },
];

export const COVERAGE_FILES = new Set([
  "Package.swift",
  "Package.resolved",
  "Makefile",
  ".github/workflows/ci.yml",
]);

/** Is a repository-relative path capable of changing source coverage evidence? */
export function isCoverageAffecting(file) {
  const normalized = file.replace(/^\.\//, "").replace(/^\/+/, "");
  return COVERAGE_FILES.has(normalized)
    || COVERAGE_AFFECTING.some(rule => normalized.startsWith(rule.prefix));
}

/** Classify changed repository-relative paths. */
export function classify(changedFiles, force = false) {
  const files = changedFiles.filter(isCoverageAffecting);
  return {
    required: force || files.length > 0,
    forced: force,
    files,
  };
}

export function main(argumentsArray = process.argv.slice(2)) {
  let changedFileList = null;
  let force = false;
  for (let index = 0; index < argumentsArray.length; index += 1) {
    if (argumentsArray[index] === "--changed-file-list") {
      changedFileList = argumentsArray[index + 1] ?? "";
      index += 1;
    } else if (argumentsArray[index] === "--force") {
      force = true;
    }
  }

  const changedFiles = changedFileList
    ? fs.readFileSync(changedFileList, "utf8").split(/\r?\n/).filter(Boolean)
    : [];
  const result = classify(changedFiles, force);
  console.log(`coverage=${result.required ? "required" : "fastpath"}`);
  if (result.forced) {
    console.log("coverage required by explicit full-run request");
  } else if (result.required) {
    console.log(`${result.files.length} coverage-affecting path(s) changed`);
    for (const file of result.files) console.log(`  - ${file}`);
  } else {
    console.log("no coverage-affecting paths changed; source coverage build skipped");
  }
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main();
