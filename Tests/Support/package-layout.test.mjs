// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(new URL("../..", import.meta.url).pathname);
const testsRoot = path.join(root, "Tests");
const excludedDirectories = new Set(["AxolotyWire", "Support"]);
const resourceDirectory = path.join("WireCompatibility", "Fixtures");

function walk(directory, relative = "") {
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  return entries.flatMap(entry => {
    const entryRelative = path.join(relative, entry.name);
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return walk(entryPath, entryRelative);
    return [entryRelative];
  });
}

test("compiled test roots contain Swift sources or declared fixtures only", () => {
  const unhandled = walk(testsRoot).filter(relative => {
    const firstComponent = relative.split(path.sep)[0];
    if (excludedDirectories.has(firstComponent)) return false;
    if (firstComponent.startsWith(".")) return false;
    if (relative.startsWith(`${resourceDirectory}${path.sep}`)) return false;
    return path.extname(relative) !== ".swift";
  });

  assert.deepEqual(unhandled, [], "move non-Swift test harness files under Tests/Support");
});

test("Package.swift excludes whole support directories", () => {
  const manifest = fs.readFileSync(path.join(root, "Package.swift"), "utf8");
  const excludeBlock = /\.testTarget\(\n\s+name: "AxolotyTests"[\s\S]*?exclude: \[([\s\S]*?)\],\n\s+resources:/m.exec(manifest)?.[1] ?? "";

  assert.match(excludeBlock, /"AxolotyWire"/);
  assert.match(excludeBlock, /"Support"/);
  assert.doesNotMatch(excludeBlock, /\/|\.md|\.sh|\.js/);
});
