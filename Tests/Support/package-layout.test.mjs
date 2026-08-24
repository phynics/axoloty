// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(new URL("../..", import.meta.url).pathname);
const testsRoot = path.join(root, "Tests");
const manifest = fs.readFileSync(path.join(root, "Package.swift"), "utf8");

function targetBlock(kind, name) {
  const expression = new RegExp(
    `\\n        \\.${kind}\\(\\n            name: "${name}"[\\s\\S]*?(?=\\n        \\.(?:target|testTarget|executableTarget|plugin|binaryTarget)\\()`,
  );
  const match = expression.exec(`\n${manifest}`);
  assert.ok(match, `Package.swift must declare ${kind} ${name}`);
  return match[0];
}

function targetPath(kind, name) {
  const block = targetBlock(kind, name);
  const match = /path: "([^"]+)"/.exec(block);
  assert.ok(match, `${name} must declare an owning path`);
  return match[1];
}

function walk(directory, relative = "") {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const entryRelative = path.join(relative, entry.name);
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) return walk(entryPath, entryRelative);
    return [entryRelative.split(path.sep).join("/")];
  });
}

test("test targets have explicit ownership and no per-file root selection", () => {
  const ordinary = targetBlock("testTarget", "AxolotyTests");
  assert.match(ordinary, /path: "Tests\/AxolotyTests"/);
  assert.doesNotMatch(ordinary, /\b(?:sources|exclude):\s*\[/);
  assert.match(ordinary, /\.copy\("ProtocolTrace\/trace\.schema\.json"\)/);
  assert.match(ordinary, /\.copy\("ProtocolTrace\/Fixtures\/family-seeds\.json"\)/);
  assert.match(ordinary, /\.copy\("WireCompatibility\/Fixtures"\)/);

  assert.equal(targetPath("target", "AxolotyTestSupport"), "Tests/AxolotyTestSupport");
  assert.equal(targetPath("testTarget", "AxolotyLiveWireTests"), "Tests/AxolotyLiveWireTests");
  assert.doesNotMatch(targetBlock("testTarget", "AxolotyLiveWireTests"), /\b(?:sources|exclude):\s*\[/);
});

test("Swift files outside orchestration support belong to one declared test target", () => {
  const ownedRoots = [
    "AxolotyTests",
    "AxolotyLiveWireTests",
    "AxolotyTestSupport",
    "AxolotyWire",
  ];
  const unowned = walk(testsRoot)
    .filter(relative => relative.endsWith(".swift"))
    .filter(relative => !relative.startsWith("Support/"))
    .filter(relative => !ownedRoots.some(rootPath => relative === rootPath || relative.startsWith(`${rootPath}/`)));
  assert.deepEqual(unowned, [], "Swift test files must live under an owned target path");
});

test("all live-wire tests are environment-gated", () => {
  const liveRoot = path.join(testsRoot, "AxolotyLiveWireTests");
  const liveFiles = walk(liveRoot)
    .filter(relative => relative.endsWith(".swift"));
  assert.ok(liveFiles.length > 0, "live target must contain Swift subjects");
  for (const relative of liveFiles) {
    const source = fs.readFileSync(path.join(liveRoot, relative), "utf8");
    const testCount = source.match(/@Test\b/g)?.length ?? 0;
    if (testCount > 0) {
      const enabledCount = source.match(/@Test\s*\(\s*\.enabled\s*\(/g)?.length ?? 0;
      assert.equal(enabledCount, testCount, `${relative} must gate every live test`);
    }
  }
});

test("test target directories do not overlap", () => {
  const roots = [
    targetPath("testTarget", "AxolotyTests"),
    targetPath("testTarget", "AxolotyLiveWireTests"),
    targetPath("target", "AxolotyTestSupport"),
    targetPath("testTarget", "AxolotyWireTests"),
  ];
  for (const first of roots) {
    for (const second of roots) {
      if (first !== second) {
        assert.ok(!first.startsWith(`${second}/`), `${first} overlaps ${second}`);
      }
    }
  }
});
