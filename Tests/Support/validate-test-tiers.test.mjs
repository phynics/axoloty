// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { discoverSelfTests, parseMakeTargets, validate } from "./validate-test-tiers.mjs";

const root = path.resolve(import.meta.dirname, "../..");

test("checked-in contract covers discovered self-tests", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: discoverSelfTests(path.join(root, "Tests")),
    exists: relative => fs.existsSync(path.join(root, relative)),
  });
  assert.deepEqual(errors, []);
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

test("validator rejects duplicate ownership and unknown targets", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.selfTests.push({ ...document.selfTests[0] });
  document.tiers[0].makeTarget = "not-a-target";
  const errors = validate(document, { makeTargets: new Set(["test-support"]), discoveredSelfTests: [], exists: () => true });
  assert.ok(errors.some(error => error.includes("not a Makefile target")));
  assert.ok(errors.some(error => error.includes("duplicate ownership")));
});
