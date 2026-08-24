// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(new URL("../..", import.meta.url).pathname);
const testsRoot = path.join(root, "Tests");

function axolotyTestsTarget() {
  const manifest = fs.readFileSync(path.join(root, "Package.swift"), "utf8");
  const start = manifest.indexOf('.testTarget(\n            name: "AxolotyTests"');
  const end = manifest.indexOf("\n        .testTarget(", start + 1);
  assert.notEqual(start, -1, "Package.swift must declare AxolotyTests");
  assert.notEqual(end, -1, "AxolotyTests must be followed by another test target");
  return manifest.slice(start, end);
}

function manifestPaths(label) {
  const match = new RegExp(`${label}: \\[([\\s\\S]*?)\\]`).exec(axolotyTestsTarget());
  assert.ok(match, `AxolotyTests must declare ${label}`);
  return [...match[1].matchAll(/"([^"]+)"/g)].map(([, value]) => value);
}

function posix(relative) {
  return relative.split(path.sep).join("/");
}

function isUnder(relative, declaredPath) {
  return relative === declaredPath || relative.startsWith(`${declaredPath}/`);
}

function walk(directory, relative = "") {
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  return entries.flatMap(entry => {
    const entryRelative = path.join(relative, entry.name);
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return walk(entryPath, entryRelative);
    return [entryRelative];
  });
}

test("AxolotyTests partitions every test-tree file", () => {
  const sources = manifestPaths("sources");
  const excludes = manifestPaths("exclude");
  const resources = manifestPaths("resources");
  const files = walk(testsRoot)
    .map(posix)
    .filter(relative => !relative.split("/").some(component => component.startsWith(".")));

  const sourceSet = new Set(sources);
  assert.equal(sourceSet.size, sources.length, "compiled source paths must be unique");
  assert.equal(new Set(excludes).size, excludes.length, "exclusion paths must be unique");
  assert.equal(new Set(resources).size, resources.length, "resource paths must be unique");
  const overlappingSources = sources.filter(source =>
    excludes.some(exclude => isUnder(source, exclude)) ||
    resources.some(resource => isUnder(source, resource))
  );
  const overlappingResources = resources.filter(resource =>
    excludes.some(exclude => isUnder(resource, exclude)) ||
    sources.some(source => isUnder(source, resource))
  );
  assert.deepEqual(overlappingSources, [], "compiled sources must not be excluded or treated as resources");
  assert.deepEqual(overlappingResources, [], "resources must not be excluded or compiled as sources");

  const unhandled = files.filter(relative => {
    const declaredSource = sourceSet.has(relative);
    const declaredResource = resources.some(resource => isUnder(relative, resource));
    const declaredExclude = excludes.some(exclude => isUnder(relative, exclude));
    return !declaredSource && !declaredResource && !declaredExclude;
  });
  assert.deepEqual(unhandled, [], "every test-tree file must be a source, resource, or explicit exclusion");

  const missingSources = sources.filter(source => !files.includes(source));
  const missingResources = resources.filter(resource =>
    !files.some(relative => isUnder(relative, resource)) && !files.includes(resource)
  );
  const missingExcludes = excludes.filter(exclude =>
    !files.some(relative => isUnder(relative, exclude)) && !files.includes(exclude)
  );
  assert.deepEqual(missingSources, [], "compiled source paths must exist");
  assert.deepEqual(missingResources, [], "resource paths must exist");
  assert.deepEqual(missingExcludes, [], "exclusion paths must exist");
});

test("Package.swift excludes whole support directories", () => {
  const excludes = manifestPaths("exclude");
  assert.ok(excludes.includes("AxolotyWire"));
  assert.ok(excludes.includes("Support"));
});
