// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { classify, isProtocolAffecting, main, PROTOCOL_AFFECTING } from "./classify-wire-change.mjs";

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "classify-wire-change.mjs");

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
    ["Tests/WireCompatibility/Fixtures/advertise.jsonl", true],
    ["Tests/Support/WireCompatibility/tool/src/capture.ts", true],
    ["Tests/Support/WireCompatibility/Live/run-coatyjs-core.sh", true],
    ["Tests/AxolotyWire/WireCodecTests.swift", true],
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
