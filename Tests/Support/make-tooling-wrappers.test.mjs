// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

function recipe(makefile, target) {
  const match = new RegExp(`^${target}:[^\\n]*\\n((?:\\t[^\\n]*\\n)+)`, "m").exec(makefile);
  assert.ok(match, `missing Make target: ${target}`);
  return match[1];
}

function swiftCodeBlockAfter(document, marker) {
  const markerIndex = document.indexOf(marker);
  assert.notEqual(markerIndex, -1, `missing documentation marker: ${marker}`);
  const match = /```swift\n([\s\S]*?)\n```/.exec(document.slice(markerIndex));
  assert.ok(match, `missing Swift code block after: ${marker}`);
  return match[1];
}

test("principal Make workflows are direct axoloty-tool wrappers", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  const recursiveTargets = [
    "check",
    "build",
    "test-tooling",
    "test-wire",
    "test-wire-live",
    "embedded-toolchain-doctor",
    "embedded-swift-build",
    "check-embedded-swift-linker",
    "hardware-check",
    "hardware-require",
    "g1-bounded-runtime-device",
    "release-fixture-bundle",
  ];
  for (const target of recursiveTargets) {
    assert.match(recipe(makefile, target), /\$\(MAKE\).*\baxoloty-tool\b/, `${target} must forward to axoloty-tool`);
  }
  for (const target of ["verify", "verify-ci", "test-one", "test-tier", "explain"]) {
    assert.match(recipe(makefile, target), /(?:\.devcontainer\/run\.sh.*axoloty-tool|\$\(MAKE\).*\baxoloty-tool\b)/, `${target} must run axoloty-tool in the pinned container`);
  }
});

test("G1 device wrapper delegates policy and device access to axoloty-tool", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  const target = recipe(makefile, "g1-bounded-runtime-device");
  assert.match(target, /AXOLOTY_TOOL_ARGS='test-one --filter g1-bounded-runtime-device'/);
  assert.match(target, /AXOLOTY_TOOL_CONTAINER_OPTIONAL_DEVICES='\$\(AXOLOTY_DEVICE\)'/);
  assert.doesNotMatch(target, /\.devcontainer\/run\.sh|CONTAINER_DEVICES=/);
});

test("support runs the Embedded Swift self-test in the pinned container", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  assert.match(makefile, /^test-support: resolve$/m);
  assert.match(
    recipe(makefile, "test-support"),
    /\.devcontainer\/run\.sh \/workspace\/Tests\/Support\/test-check-embedded-swift\.sh/,
  );
});

test("support benchmark self-test uses the worktree build and SwiftPM caches", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  assert.match(
    recipe(makefile, "test-support"),
    /BUILD_DIR="\$\(BUILD_DIR\)" SPM_CACHE_DIR="\$\(SPM_CACHE_DIR\)" \\\n\s*Tests\/Support\/test-check-benchmark-wire\.sh/,
  );
});

test("README package integration links both products by repository identity", () => {
  const readme = fs.readFileSync("README.md", "utf8");
  const packageIntegration = readme.slice(
    readme.indexOf("### Swift Package Manager"),
    readme.indexOf("### Minimal host example"),
  );
  assert.match(packageIntegration, /\.product\(name: "Axoloty", package: "axoloty"\)/);
  assert.match(packageIntegration, /\.product\(name: "AxolotyWire", package: "axoloty"\)/);
});

test("host consumer journey stays synchronized across source and documentation", () => {
  const fixture = fs.readFileSync("Tests/Support/fixtures/semver-consumer/AxolotyConsumer/main.swift", "utf8")
    .replace(/^\/\/ Copyright[^\n]*\n\n/, "")
    .trimEnd();
  const readme = swiftCodeBlockAfter(fs.readFileSync("README.md", "utf8"), "### Minimal host example");
  const docc = swiftCodeBlockAfter(fs.readFileSync("Source/Axoloty.docc/GettingStarted.md", "utf8"), "## Configure and start a container");
  assert.equal(readme, fixture, "README host example must match the compiled consumer fixture");
  assert.equal(docc, fixture, "DocC host example must match the compiled consumer fixture");
});
