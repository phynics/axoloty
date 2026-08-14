// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { discoverSelfTests, discoverTargetSelfTests, parseMakeTargets, validate } from "./validate-test-tiers.mjs";

const root = path.resolve(import.meta.dirname, "../..");

test("checked-in contract covers discovered self-tests", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: discoverSelfTests(path.join(root, "Tests")),
    invokedSelfTests: discoverTargetSelfTests(path.join(root, "Makefile"), document.selfTests.map(entry => entry.path)),
    exists: relative => fs.existsSync(path.join(root, relative)),
  });
  assert.deepEqual(errors, []);
});

test("cold semver consumer gates allow a full dual-configuration build", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  for (const id of ["checkpoint-semver-consumer", "release-semver-consumer"]) {
    const node = document.nodes.find(candidate => candidate.id === id);
    assert.equal(node.timeoutSeconds, 1800, id);
    assert.equal(node.expectedDurationSeconds, 900, id);
  }
});

test("cold semver consumer bounds SwiftPM build parallelism", () => {
  const script = fs.readFileSync(path.join(root, "Tests/Support/check-axoloty-semver-consumer.sh"), "utf8");
  assert.match(script, /jobs=\$\{AXOLOTY_CONSUMER_JOBS:-2\}/);
  assert.match(script, /swift build --jobs "\$jobs" --configuration "\$configuration" --target WireConsumer/);
  assert.match(script, /swift build --jobs "\$jobs" --configuration "\$configuration" --target AxolotyConsumer/);
});

test("make parser ignores assignments and special targets", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-tiers-"));
  const makefile = path.join(directory, "Makefile");
  fs.writeFileSync(makefile, "VALUE := x\n.PHONY: test\ntest: dependency\nname-with-dot.x:\n");
  assert.deepEqual([...parseMakeTargets(makefile)].sort(), ["name-with-dot.x", "test"]);
});

test("discovery includes shell and Node self-tests", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-tests-"));
  const tests = path.join(directory, "Tests");
  fs.mkdirSync(path.join(tests, "Support"), { recursive: true });
  fs.writeFileSync(path.join(tests, "Support/test-one.sh"), "");
  fs.writeFileSync(path.join(tests, "Support/one.test.mjs"), "");
  assert.deepEqual(discoverSelfTests(tests), ["Tests/Support/one.test.mjs", "Tests/Support/test-one.sh"]);
});

test("target self-test discovery recognizes shell commands and Node test globs", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-invocations-"));
  const makefile = path.join(directory, "Makefile");
  fs.writeFileSync(makefile, "test-support:\n\t/workspace/Tests/Support/test-one.sh\n\tnode --test Tests/Support/*.test.mjs\n");
  const invoked = discoverTargetSelfTests(makefile, [
    "Tests/Support/one.test.mjs",
    "Tests/Support/nested/one.test.mjs",
    "Tests/Support/test-one.sh",
    "Tests/Support/test-two.sh",
  ]);
  assert.deepEqual(invoked, new Map([["test-support", new Set([
    "Tests/Support/one.test.mjs",
    "Tests/Support/test-one.sh",
  ])]]));
});

test("target self-test discovery ignores path mentions outside executable positions", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-invocations-"));
  const makefile = path.join(directory, "Makefile");
  fs.writeFileSync(makefile, "test-support:\n\tprintf '%s\\n' Tests/Support/test-one.sh\n\tsh Tests/Support/test-two.sh\n");
  const invoked = discoverTargetSelfTests(makefile, [
    "Tests/Support/test-one.sh",
    "Tests/Support/test-two.sh",
  ]);
  assert.deepEqual(invoked, new Map([["test-support", new Set(["Tests/Support/test-two.sh"])]]));
});

test("target self-test discovery only counts the shell script operand", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-invocations-"));
  const makefile = path.join(directory, "Makefile");
  fs.writeFileSync(makefile, "test-support:\n\tsh wrapper.sh Tests/Support/test-one.sh\n\tbash -eu Tests/Support/test-two.sh fixture\n");
  const invoked = discoverTargetSelfTests(makefile, [
    "Tests/Support/test-one.sh",
    "Tests/Support/test-two.sh",
  ]);
  assert.deepEqual(invoked, new Map([["test-support", new Set(["Tests/Support/test-two.sh"])]]));
});

test("target self-test discovery recursively unwraps the devcontainer runner", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-invocations-"));
  const makefile = path.join(directory, "Makefile");
  fs.writeFileSync(makefile, "test-support:\n\t.devcontainer/run.sh sh Tests/Support/test-one.sh\n\t.devcontainer/run.sh sh wrapper.sh Tests/Support/test-two.sh\n");
  const invoked = discoverTargetSelfTests(makefile, [
    "Tests/Support/test-one.sh",
    "Tests/Support/test-two.sh",
  ]);
  assert.deepEqual(invoked, new Map([["test-support", new Set(["Tests/Support/test-one.sh"])]]));
});

test("target self-test discovery follows recursive Make wrappers without looping", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-invocations-"));
  const makefile = path.join(directory, "Makefile");
  fs.writeFileSync(makefile, "test-support:\n\t$(MAKE) --no-print-directory child-target\nchild-target:\n\tTests/Support/test-one.sh\ncycle-a:\n\t$(MAKE) cycle-b\n\tTests/Support/test-one.sh\ncycle-b:\n\t$(MAKE) cycle-a\n\tTests/Support/test-two.sh\n");
  const invoked = discoverTargetSelfTests(makefile, ["Tests/Support/test-one.sh", "Tests/Support/test-two.sh"]);
  assert.deepEqual(invoked.get("test-support"), new Set(["Tests/Support/test-one.sh"]));
  assert.deepEqual(invoked.get("cycle-a"), new Set(["Tests/Support/test-one.sh", "Tests/Support/test-two.sh"]));
  assert.deepEqual(invoked.get("cycle-b"), new Set(["Tests/Support/test-one.sh", "Tests/Support/test-two.sh"]));
});

test("validator rejects duplicate ownership and unknown targets", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.selfTests.push({ ...document.selfTests[0] });
  document.tiers[0].makeTarget = "not-a-target";
  const errors = validate(document, { makeTargets: new Set(["test-support"]), discoveredSelfTests: [], exists: () => true });
  assert.ok(errors.some(error => error.includes("not a Makefile target")));
  assert.ok(errors.some(error => error.includes("duplicate ownership")));
});

test("validator rejects an owned self-test its target does not invoke", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const omitted = "Tests/Support/test-check-benchmark-size.sh";
  const invokedSelfTests = new Map([["test-support", new Set(document.selfTests.map(entry => entry.path).filter(entry => entry !== omitted))]]);
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    invokedSelfTests,
    exists: () => true,
  });
  assert.ok(errors.some(error => error.includes(`${omitted}: makeTarget "test-support" does not invoke it`)));
});

test("validator rejects required-gate metadata weakened with the gate list", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.requiredGates = document.requiredGates.filter(node => node !== "support-tier-contract");
  document.nodes.find(node => node.id === "support-tier-contract").required = true;
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.some(error => error.includes('required node "support-tier-contract" is absent from requiredGates')));
});

test("validator rejects duplicated verify roots", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.plans.verify.nodes = ["build"];
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.some(error => error.includes("verify roots must be derived")));
});

test("validator CLI reports stable selfTests schema errors", t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-tool-tiers-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const base = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const cases = [
    ["missing", document => { delete document.selfTests; }, "selfTests must be an array"],
    ["null", document => { document.selfTests = null; }, "selfTests must be an array"],
    ["non-array", document => { document.selfTests = {}; }, "selfTests must be an array"],
    ["malformed-entry", document => { document.selfTests = [null]; }, "selfTests entries must be objects"],
  ];

  for (const [name, mutate, expected] of cases) {
    const document = structuredClone(base);
    mutate(document);
    const config = path.join(directory, `${name}.json`);
    fs.writeFileSync(config, JSON.stringify(document));
    const result = spawnSync(process.execPath, [path.join(root, "Tests/Support/validate-test-tiers.mjs"), config], { encoding: "utf8" });
    assert.equal(result.status, 1, name);
    assert.match(result.stderr, new RegExp(`test-tier configuration error: ${expected}`), name);
    assert.doesNotMatch(result.stderr, /TypeError|Cannot read properties|\.map is not a function/, name);
  }
});
