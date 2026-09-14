// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";

function canonicalDirectory(value, name) {
  if (!value || !path.isAbsolute(value)) {
    throw new Error(`${name} must be an absolute path`);
  }
  let resolved;
  try {
    resolved = fs.realpathSync(value);
  } catch {
    throw new Error(`${name} does not exist: ${value}`);
  }
  if (!fs.statSync(resolved).isDirectory()) {
    throw new Error(`${name} is not a directory: ${value}`);
  }
  return resolved;
}

function canonicalManifest(value) {
  if (!value || !path.isAbsolute(value)) {
    throw new Error("EMBEDDED_CORPUS_MANIFEST must be an absolute path");
  }
  let resolved;
  try {
    resolved = fs.realpathSync(value);
  } catch {
    throw new Error(`EMBEDDED_CORPUS_MANIFEST does not exist: ${value}`);
  }
  if (!fs.statSync(resolved).isFile()) {
    throw new Error(`EMBEDDED_CORPUS_MANIFEST is not a file: ${value}`);
  }
  return resolved;
}

/** Resolves and validates the fixture manifest owned by the firmware project. */
export function resolveEmbeddedCorpusManifest() {
  const projectDir = canonicalDirectory(
    process.env.EMBEDDED_PROJECT_DIR,
    "EMBEDDED_PROJECT_DIR",
  );
  const manifestPath = canonicalManifest(
    process.env.EMBEDDED_CORPUS_MANIFEST ||
      path.join(projectDir, "fixtures", "manifest.json"),
  );
  const relativePath = path.relative(projectDir, manifestPath);
  if (
    relativePath === "" ||
    relativePath === ".." ||
    relativePath.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relativePath)
  ) {
    throw new Error(
      `EMBEDDED_CORPUS_MANIFEST must be inside EMBEDDED_PROJECT_DIR: ${manifestPath}`,
    );
  }

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(`cannot read EMBEDDED_CORPUS_MANIFEST: ${error.message}`);
  }
  if (!Array.isArray(manifest.cases)) {
    throw new Error("EMBEDDED_CORPUS_MANIFEST.cases must be an array");
  }
  return manifest;
}
