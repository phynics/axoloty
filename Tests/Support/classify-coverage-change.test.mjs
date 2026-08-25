// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { classify, isCoverageAffecting, main } from "./classify-coverage-change.mjs";

test("source, tests, manifests, toolchain, and the owning workflow require coverage", () => {
  for (const file of [
    "Source/Runtime/AxolotyRuntime.swift",
    "Packages/AxolotyWire/Sources/AxolotyWire/WireReader.swift",
    "Tools/AxolotyTooling/AxolotyCheck.swift",
    "Tests/AxolotyToolingTests/AxolotyCheckTests.swift",
    "Embedded/swift/main/Main.swift",
    ".devcontainer/Dockerfile",
    ".github/actions/setup-container/action.yml",
    ".github/workflows/ci.yml",
    "Package.swift",
    "Package.resolved",
    "Makefile",
  ]) {
    assert.equal(isCoverageAffecting(file), true, file);
  }
});

test("documentation and unrelated automation stay on the fast path", () => {
  for (const file of [
    "README.md",
    "docs/ROADMAP.md",
    "docs/adr/001-example.md",
    ".github/workflows/docs.yml",
    ".github/ISSUE_TEMPLATE/work-plan.yml",
    "LICENSE",
    "AGENTS.md",
  ]) {
    assert.equal(isCoverageAffecting(file), false, file);
  }
});

test("classification reports affecting paths and explicit full runs override the fast path", () => {
  assert.deepEqual(classify(["README.md", "Source/Runtime/AxolotyRuntime.swift"]), {
    required: true,
    forced: false,
    files: ["Source/Runtime/AxolotyRuntime.swift"],
  });
  assert.deepEqual(classify(["README.md"]), { required: false, forced: false, files: [] });
  assert.deepEqual(classify([], true), { required: true, forced: true, files: [] });
});

test("CLI preserves paths containing spaces and emits a stable marker", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-coverage-classifier-"));
  const changed = path.join(temporary, "changed-paths.txt");
  fs.writeFileSync(changed, "Source/Model/Core Types/CoatyObject.swift\nREADME.md\n");
  const output = [];
  const originalLog = console.log;
  console.log = value => output.push(value);
  try {
    assert.equal(main(["--changed-file-list", changed]), 0);
  } finally {
    console.log = originalLog;
    fs.rmSync(temporary, { force: true, recursive: true });
  }
  assert.equal(output[0], "coverage=required");
  assert.match(output.join("\n"), /Source\/Model\/Core Types\/CoatyObject\.swift/);
});
