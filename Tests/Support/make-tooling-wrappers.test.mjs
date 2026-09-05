// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { parseMakeTargets } from "./validate-test-tiers.mjs";

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

function advertisedHelpEntries(output) {
  return output.split(/\r?\n/).filter(line => line.startsWith("make ")).map(line => {
    const separator = line.search(/\s{2,}/);
    assert.ok(separator > 0, `help entry has no description: ${line}`);
    const invocation = line.slice("make ".length, separator).trim();
    const description = line.slice(separator).trim();
    return { target: invocation.split(/\s+/, 1)[0], description };
  });
}

test("make help advertises only declared, documented targets", () => {
  const result = spawnSync("make", ["--no-print-directory", "help"], { encoding: "utf8" });
  assert.equal(result.status, 0, `make help failed: ${result.stderr}`);
  const entries = advertisedHelpEntries(result.stdout);
  const targets = parseMakeTargets("Makefile");
  const names = new Set();
  for (const entry of entries) {
    assert.ok(!names.has(entry.target), `make help documents ${entry.target} more than once`);
    names.add(entry.target);
    assert.ok(targets.has(entry.target), `make help advertises undeclared target: ${entry.target}`);
    assert.match(entry.description, /\S/, `make help has no documentation for ${entry.target}`);
  }
  assert.ok(entries.length > 0, "make help must document at least one target");
});

test("principal Make workflows use the canonical tooling entry points", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  const advertisedTargets = [...makefile.matchAll(/'make ([A-Za-z0-9-]+)/g)].map((match) => match[1]);
  for (const target of advertisedTargets) {
    assert.match(makefile, new RegExp(`^${target}:[^\\n]*$`, "m"), `${target} is advertised but has no Make rule`);
  }
  const tierTargets = [
    "build",
    "test-unit",
    "test-module",
    "test-wire",
  ];
  const tierMappings = {
    build: "smoke",
    "test-unit": "unit",
    "test-module": "module",
    "test-wire": "wire-offline",
  };
  assert.match(makefile, /define run_test_tier[\s\S]+?test-tier TIER=/);
  for (const target of tierTargets) {
    assert.match(recipe(makefile, target), /\$\(run_test_tier\)/, `${target} must use the shared tier wrapper`);
    assert.match(makefile, new RegExp(`^${target}: TIER=${tierMappings[target]}$`, "m"));
  }
  for (const target of [
    "test-wire-live",
    "embedded-toolchain-doctor",
    "embedded-swift-build",
    "check-embedded-swift-linker",
    "hardware-check",
    "hardware-require",
    "g1-bounded-runtime-device",
    "release-fixture-bundle",
  ]) {
    assert.match(recipe(makefile, target), /\$\(MAKE\).*\baxoloty-tool\b/, `${target} must forward to axoloty-tool`);
  }
  for (const target of ["verify", "verify-ci", "test-one", "test-tier", "explain"]) {
    assert.match(recipe(makefile, target), /(?:\.devcontainer\/run\.sh.*axoloty-tool|\$\(MAKE\).*\baxoloty-tool\b)/, `${target} must run axoloty-tool in the pinned container`);
  }
  for (const target of [
    "check",
    "test-tooling",
    "wire-codec-test",
    "test-communication",
    "test-observation-linux",
    "test-fast",
    "ci-fast",
    "test-wire-all",
    "broker",
    "broker-stop",
    "embedded-mqtt-test",
  ]) {
    assert.doesNotMatch(makefile, new RegExp(`^${target}:`, "m"), `${target} should not remain a Make target`);
  }

  for (const target of [
    "release-fixture-bundle",
    "test-axoloty-wire-independent-resolution",
    "test-axoloty-wire-distribution",
    "check-embedded-swift",
    "embedded-device-info",
    "embedded-device-smoke",
    "embedded-reproducible-build",
    "embedded-swift-reproducible-build",
    "embedded-network-test",
    "embedded-agent-test",
    "embedded-coatyjs-test",
    "embedded-host-test",
    "embedded-last-will-test",
    "embedded-broker-restart-test",
  ]) {
    assert.match(makefile, new RegExp(`^${target}:.*\\bimage\\b`, "m"), `${target} must establish the dev image`);
  }
});

test("decoder-context diagnostic distinguishes matching, clean, and invalid input", () => {
  const checker = "Tests/Support/check-decoder-context-diagnostic.sh";
  const missing = spawnSync("sh", [checker, path.join(os.tmpdir(), `axoloty-missing-${process.pid}`)], { encoding: "utf8" });
  assert.equal(missing.status, 2, missing.stderr);

  const matchingPath = path.join(os.tmpdir(), `axoloty-matching-${process.pid}.log`);
  const cleanPath = path.join(os.tmpdir(), `axoloty-clean-${process.pid}.log`);
  const unreadablePath = path.join(os.tmpdir(), `axoloty-unreadable-${process.pid}`);
  fs.writeFileSync(matchingPath, "Source/Common/Decoder+Context.swift:42: warning\n  type 'Any' does not conform to the 'Sendable' protocol\n");
  fs.writeFileSync(cleanPath, "build completed without diagnostics\\n");
  fs.mkdirSync(unreadablePath);
  try {
    const matching = spawnSync("sh", [checker, matchingPath], { encoding: "utf8" });
    assert.equal(matching.status, 1, matching.stderr);
    const clean = spawnSync("sh", [checker, cleanPath], { encoding: "utf8" });
    assert.equal(clean.status, 0, clean.stderr);
    const unreadable = spawnSync("sh", [checker, unreadablePath], { encoding: "utf8" });
    assert.equal(unreadable.status, 2, unreadable.stderr);
  } finally {
    fs.rmSync(matchingPath, { force: true });
    fs.rmSync(cleanPath, { force: true });
    fs.rmSync(unreadablePath, { recursive: true, force: true });
  }
});

test("retired broker wrapper is fully removed rather than a stub", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  assert.doesNotMatch(makefile, /^test:\s*$/m);
  assert.doesNotMatch(makefile, /make test is retired/);
});

test("direct test wrappers preserve the invocation resource namespace", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  assert.match(
    makefile,
    /AXOLOTY_RUN_CONTAINER_ENV_VARS := AXOLOTY_RUN_ID AXOLOTY_RUNS_DIR WIRE_OUTPUT_DIR AXOLOTY_RESOURCE_LEASE_ROOT/,
  );
  for (const target of ["test-one", "test-tier"]) {
    assert.match(
      recipe(makefile, target),
      /CONTAINER_ENV_VARS="\$\(AXOLOTY_RUN_CONTAINER_ENV_VARS\)"/,
      `${target} must forward run-scoped values into the project container`,
    );
  }
});

test("service wrappers forward an explicit MCP executable override", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  for (const target of ["serve-mcp", "serve-dev"]) {
    assert.match(
      recipe(makefile, target),
      /CONTAINER_ENV_VARS=AXOLOTY_MCP_EXECUTABLE/,
      `${target} must pass AXOLOTY_MCP_EXECUTABLE into the container`,
    );
  }
});

test("G1 device wrapper delegates policy and device access to axoloty-tool", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  const target = recipe(makefile, "g1-bounded-runtime-device");
  assert.match(target, /AXOLOTY_TOOL_ARGS='test-one --filter g1-bounded-runtime-device'/);
  assert.match(target, /AXOLOTY_TOOL_CONTAINER_OPTIONAL_DEVICES='\$\(AXOLOTY_DEVICE\)'/);
  assert.doesNotMatch(target, /\.devcontainer\/run\.sh|CONTAINER_DEVICES=/);
});

test("support self-tests run as the canonical support tier in the pinned container", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  assert.match(makefile, /^test-support: resolve$/m);
  assert.match(
    recipe(makefile, "test-support"),
    /\$\(MAKE\) --no-print-directory test-tier TIER=support/,
  );
  const document = JSON.parse(fs.readFileSync("Tests/Support/test-tiers.json", "utf8"));
  const tier = document.tiers.find(candidate => candidate.id === "support");
  const node = document.nodes.find(candidate => candidate.id === "support-embedded-compile");
  assert.ok(tier.nodes.includes("support-embedded-compile"));
  assert.equal(node.command.executable, "Tests/Support/test-check-embedded-swift.sh");
});

test("support benchmark self-test keeps the worktree build and SwiftPM caches", () => {
  const document = JSON.parse(fs.readFileSync("Tests/Support/test-tiers.json", "utf8"));
  const node = document.nodes.find(candidate => candidate.id === "support-benchmark-wire");
  assert.equal(node.command.executable, "Tests/Support/test-check-benchmark-wire.sh");
  const tier = document.tiers.find(candidate => candidate.id === "support");
  assert.ok(tier.nodes.includes("support-benchmark-wire"));
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
  const docc = swiftCodeBlockAfter(fs.readFileSync("Source/Axoloty.docc/GettingStarted.md", "utf8"), "## Define and start a runtime");
  assert.equal(readme, fixture, "README host example must match the compiled consumer fixture");
  assert.equal(docc, fixture, "DocC host example must match the compiled consumer fixture");
});

test("docs generation forwards the hosting base path across the container boundary", () => {
  // run.sh forwards only names listed in CONTAINER_ENV_VARS, so exporting
  // DOC_HOSTING_BASE_PATH on the recipe line is not enough on its own.
  const target = recipe(fs.readFileSync("Makefile", "utf8"), "docs");
  assert.match(target, /DOC_HOSTING_BASE_PATH="\$\(DOC_HOSTING_BASE_PATH\)"/);
  assert.match(target, /CONTAINER_ENV_VARS=[^\n]*\bDOC_HOSTING_BASE_PATH\b/);

  const script = fs.readFileSync(".github/scripts/build-docs.sh", "utf8");
  assert.match(script, /--hosting-base-path \$\{DOC_HOSTING_BASE_PATH\}/);
  // The prepared renderer is only used when DocC is pointed at it.
  assert.match(script, /prepare-docc-renderer\.sh \.build\/docc-renderer/);
  assert.match(script, /DOCC_HTML_DIR=\/workspace\/\.build\/docc-renderer/);
});

test("release targets fail closed when the container env allowlist is unavailable", () => {
  const makefile = fs.readFileSync("Makefile", "utf8");
  const helper = "Tests/Support/tool-container-env.sh";
  for (const [target, command] of [
    ["release-fixture-bundle", "release-fixture-bundle"],
    ["checkpoint", "release-checkpoint"],
    ["checkpoint-hardware", "release-checkpoint-hardware"],
  ]) {
    const target_recipe = recipe(makefile, target);
    // The helper runs node on the host; an unchecked command substitution
    // would yield an empty allowlist and still run the release.
    assert.match(target_recipe, new RegExp(`container_env="\\$\\$\\(sh ${helper} ${command}\\)" \\|\\| exit 1`));
    assert.match(target_recipe, /test -n "\$\$container_env" \|\| \{ echo/);
    assert.match(target_recipe, /AXOLOTY_TOOL_CONTAINER_ENV_VARS="\$\$container_env"/);
  }

  const missing = spawnSync("sh", [helper, "release-unknown"], { encoding: "utf8" });
  assert.equal(missing.status, 1, missing.stderr);
  assert.match(missing.stderr, /no allowlist for release-unknown/);
  assert.equal(missing.stdout, "");
});
