// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { classify, isProtocolAffecting, main, PROTOCOL_AFFECTING } from "../wire/classify-wire-change.mjs";

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "../wire/classify-wire-change.mjs");
const runRecorder = path.join(path.dirname(fileURLToPath(import.meta.url)), "../WireCompatibility/Live/record-ci-run.mjs");
const wireWorkflow = fs.readFileSync(".github/workflows/wire-compatibility.yml", "utf8");

function workflowStep(name) {
  const marker = `      - name: ${name}`;
  const start = wireWorkflow.indexOf(marker);
  assert.notEqual(start, -1, `missing workflow step: ${name}`);
  const end = wireWorkflow.indexOf("\n      - name:", start + marker.length);
  return wireWorkflow.slice(start, end === -1 ? undefined : end);
}

test("protocol-affecting globs cover wire codec and core types", () => {
  const cases = [
    ["Source/Communication/Events/AdvertiseEvent.swift", true],
    ["Source/Communication/Events/CallEvent.swift", true],
    ["Packages/AxolotyWire/Sources/AxolotyWire/WireWriter.swift", true],
    ["Packages/AxolotyWire/Sources/AxolotyWire/TopicBuilder.swift", true],
    ["Source/Model/Core Types/CoatyObject.swift", true],
    ["Source/IORouting/IoRouter.swift", true],
    ["Source/SensorThings/Sensor.swift", true],
    ["Source/Communication/Client/MQTTNIOClient.swift", true],
    ["Tests/AxolotyTests/WireCompatibility/Fixtures/advertise.jsonl", true],
    ["Tests/Support/WireCompatibility/tool/src/capture.ts", true],
    ["Tests/Support/WireCompatibility/Live/run-coatyjs-core.sh", true],
    ["Packages/AxolotyWire/Tests/AxolotyWireTests/WireCodecTests.swift", true],
    ["Package.swift", true],
    ["Package.resolved", true],
  ];
  for (const [file, expected] of cases) {
    assert.equal(isProtocolAffecting(file), expected, file);
  }
});

test("unrelated, documentation, orchestration, and policy changes stay on the fast path", () => {
  const cases = [
    "README.md",
    "CHANGELOG.md",
    "docs/ROADMAP.md",
    "Makefile",
    ".github/workflows/ci.yml",
    ".github/workflows/wire-compatibility.yml",
    "Source/Axoloty.docc/index.md",
    "Source/Axoloty.docc/main.md",
    "docs/wire-compatibility.md",
    "Tests/Support/WireCompatibility/Live/README.md",
    "Tests/Support/WireCompatibility/Audit/IOAndSensorThingsDecisions.md",
    "Tests/Support/test-tiers.json",
    "Tools/AxolotyTooling/AxolotyCheck.swift",
    "LICENSE",
  ];
  for (const file of cases) {
    assert.equal(isProtocolAffecting(file), false, file);
  }
});

test("subtree rules match the base directory but not siblings", () => {
  assert.equal(isProtocolAffecting("Packages/AxolotyWire"), true);
  assert.equal(isProtocolAffecting("Packages/AxolotyWire/Sources/AxolotyWire/Topic.swift"), true);
  assert.equal(isProtocolAffecting("Packages/AxolotyWireX/File.swift"), false);
  assert.equal(isProtocolAffecting("Source/Model/CoatyTimestamp.swift"), true);
  assert.equal(isProtocolAffecting("Source/IORouting"), true);
});

test("classify reports the affected files and respects an exemption", () => {
  const changed = ["Source/Communication/Events/CallEvent.swift", "README.md"];
  const result = classify(changed);
  assert.equal(result.protocolAffecting, true);
  assert.deepEqual(result.files, ["Source/Communication/Events/CallEvent.swift"]);

  const exempted = classify(changed, "issue #999 recorded decision");
  assert.equal(exempted.protocolAffecting, true);
  assert.equal(exempted.exempt, true);
});

test("CLI exits 1 for protocol-affecting without exemption, 0 otherwise", () => {
  const run = args => spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });
  assert.equal(run(["--changed", "Packages/AxolotyWire/Sources/AxolotyWire/Topic.swift"]).status, 1);
  assert.equal(run(["--changed", "README.md"]).status, 0);
  assert.equal(run(["--changed", "Packages/AxolotyWire/Sources/AxolotyWire/Topic.swift", "--exempt", "issue #999"]).status, 0);
});

test("CLI emits an unambiguous machine-readable gate marker first", () => {
  const run = args => spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });
  const required = run(["--changed", "Source/Communication/Events/CallEvent.swift"]).stdout;
  assert.match(required, /^gate=require\n/);
  const fast = run(["--changed", "docs/wire-compatibility.md"]).stdout;
  assert.match(fast, /^gate=fastpath\n/);
});

test("every rule has a glob and description and nonempty rule set", () => {
  assert.ok(PROTOCOL_AFFECTING.length >= 6);
  for (const rule of PROTOCOL_AFFECTING) {
    assert.ok(rule.glob);
    assert.ok(rule.description);
  }
});

test("main returns exit code without throwing on empty input", () => {
  assert.equal(main([]), 0);
});

test("wire CI records classification and never calls unverified captures evidence", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-wire-ci-record-"));
  const record = path.join(temporary, "run-status.json");
  const changed = path.join(temporary, "changed-paths.txt");
  fs.writeFileSync(changed, "README.md\nSource/Communication/Events/CallEvent.swift\n");
  const invoke = args => spawnSync(process.execPath, [runRecorder, "--file", record, ...args], { encoding: "utf8" });

  assert.equal(invoke(["--phase", "init", "--run-id", "wire-self-test"]).status, 0);
  assert.equal(invoke([
    "--phase", "classification", "--protocol", "1", "--exempt", "0",
    "--changed-file-list", changed,
  ]).status, 0);
  assert.equal(invoke(["--phase", "capture", "--capture-state", "failed"]).status, 0);

  const result = JSON.parse(fs.readFileSync(record, "utf8"));
  assert.deepEqual(result.classification.changedFiles, [
    "README.md",
    "Source/Communication/Events/CallEvent.swift",
  ]);
  assert.equal(result.run.id, "wire-self-test");
  assert.equal(result.classification.protocolAffecting, true);
  assert.equal(result.capture.state, "failed");
  assert.equal(result.captureEvidence, "unverified");
  assert.notEqual(result.captureEvidence, "verified");
  fs.rmSync(temporary, { force: true, recursive: true });
});

test("live wire workflow persists early status, diagnoses owned runtime, and uploads every run", () => {
  assert.match(wireWorkflow, /name: Initialize wire run record/);
  assert.match(wireWorkflow, /--phase classification/);
  assert.match(wireWorkflow, /name: Collect wire runner and owned-runtime diagnostics/);
  assert.match(wireWorkflow, /--filter "label=io\.axoloty\.run-id=\$WIRE_RUN_ID"/);
  assert.match(wireWorkflow, /owned-runtime-cleanup\.txt/);
  assert.match(wireWorkflow, /podman rm --force/);
  assert.match(wireWorkflow, /owned containers reaped/);
  assert.match(wireWorkflow, /name: Upload live wire evidence\n\s+if: always\(\)/);
  assert.match(wireWorkflow, /WIRE_OUTPUT_DIR: \.testing\/runs\/wire-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}\/wire/);
  assert.match(wireWorkflow, /WIRE_CI_EVIDENCE_ROOT: \.testing\/runs\/wire-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}\/ci/);
  assert.match(wireWorkflow, /manifest="\$WIRE_OUTPUT_DIR\/manifest\.json"/);
  assert.match(wireWorkflow, /cap_dir="\$WIRE_OUTPUT_DIR"/);
  assert.match(wireWorkflow, /\.testing\/runs\/\*\*/);
  assert.match(wireWorkflow, /if-no-files-found: error/);
  assert.doesNotMatch(wireWorkflow, /if-no-files-found: ignore/);
  assert.match(wireWorkflow, /--capture-state "\$capture_state"/);
  assert.match(wireWorkflow, /captureEvidence.*not-claimed/);
});

test("live wire workflow classifies before expensive setup", () => {
  const classification = wireWorkflow.indexOf("      - name: Classify the change set");
  const liveCondition = /if: steps\.classify\.outputs\.protocol == '1' && steps\.classify\.outputs\.exempt == '0'/;
  const expensiveSteps = [
    "Compute cache key",
    "Setup container image",
    "Restore SwiftPM dependency cache",
    "Setup Node.js",
    "Build wire CLI",
  ];

  assert.notEqual(classification, -1);
  for (const name of expensiveSteps) {
    const step = workflowStep(name);
    assert.ok(wireWorkflow.indexOf(`      - name: ${name}`) > classification, `${name} must follow classification`);
    assert.match(step, liveCondition, `${name} must run only for an unexempted live gate`);
  }
});
