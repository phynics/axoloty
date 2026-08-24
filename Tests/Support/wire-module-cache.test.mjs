// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const subjectScripts = [
  "Tests/Support/WireCompatibility/IO/Live/run-io-associate-js-to-modern.sh",
  "Tests/Support/WireCompatibility/IO/Live/run-io-associate.sh",
  "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-call-return.sh",
  "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-network.sh",
  "Tests/Support/WireCompatibility/Reverse/run-axoloty-advertise.sh",
  "Tests/Support/WireCompatibility/Reverse/run-axoloty-core.sh",
  "Tests/Support/WireCompatibility/Reverse/run-coatyjs-to-axoloty-advertise.sh",
  "Tests/Support/WireCompatibility/Reverse/run-coatyjs-to-axoloty-core.sh",
];

test("nested live-wire Swift commands isolate their module cache", () => {
  for (const relativePath of subjectScripts) {
    const source = readFileSync(path.join(root, relativePath), "utf8");
    const swiftCommands = source.match(/"\$DEV_IMAGE" swift (?:build|test)/g) ?? [];
    const isolatedCommands = source.match(/-e "SWIFTPM_MODULECACHE_OVERRIDE=\$SWIFTPM_MODULECACHE_OVERRIDE"/g) ?? [];
    const isolatedCompilerCommands = source.match(/-Xswiftc -module-cache-path -Xswiftc "\$SWIFTPM_MODULECACHE_OVERRIDE"/g) ?? [];

    assert.ok(swiftCommands.length > 0, `${relativePath} must launch Swift`);
    assert.equal(isolatedCommands.length, swiftCommands.length, relativePath);
    assert.equal(isolatedCompilerCommands.length, swiftCommands.length, relativePath);
    assert.match(source, /SWIFTPM_MODULECACHE_OVERRIDE=\/tmp\/axoloty-wire-module-cache/);
  }
});

test("live producer subjects require a run-scoped peer acknowledgement", () => {
  const contracts = [
    [
      "Tests/WireCompatibility/Reverse/AxolotyAdvertiseProducerTests.swift",
      "Tests/Support/WireCompatibility/Reverse/run-axoloty-advertise.sh",
      "Tests/Support/WireCompatibility/Reverse/coatyjs-advertise-consumer.js",
    ],
    [
      "Tests/WireCompatibility/Reverse/AxolotyCoreProducerTests.swift",
      "Tests/Support/WireCompatibility/Reverse/run-axoloty-core.sh",
      "Tests/Support/WireCompatibility/Reverse/coatyjs-core-consumer.js",
    ],
    [
      "Tests/WireCompatibility/IO/AxolotyIoAssociateTests.swift",
      "Tests/Support/WireCompatibility/IO/Live/run-io-associate.sh",
      "Tests/Support/WireCompatibility/IO/coatyjs-io-runner.js",
    ],
  ];
  const support = readFileSync(
    path.join(root, "Tests/WireCompatibility/Reverse/ModernConsumerSupport.swift"),
    "utf8",
  );
  assert.match(support, /WIRE_PEER_ACK_FILE/);
  assert.match(support, /phase == "peer-ack"/);

  for (const [subjectPath, runnerPath, peerPath] of contracts) {
    const subject = readFileSync(path.join(root, subjectPath), "utf8");
    const runner = readFileSync(path.join(root, runnerPath), "utf8");
    const peer = readFileSync(path.join(root, peerPath), "utf8");

    assert.match(subject, /awaitPeerAcknowledgement\(/, `${subjectPath} must await peer evidence`);
    assert.match(runner, /WIRE_PEER_ACK_FILE=/, `${runnerPath} must pass the marker path`);
    assert.match(runner, /WIRE_PEER_ACK_TOKEN=/, `${runnerPath} must pass a run-scoped token`);
    assert.match(runner, /rm -f[^\n]*ACK|rm -f[^\n]*ack/i, `${runnerPath} must clear stale markers`);
    assert.match(peer, /phase: "peer-ack"/, `${peerPath} must write phase-labelled evidence`);
    assert.match(peer, /WIRE_PEER_ACK_TOKEN/, `${peerPath} must bind evidence to the run token`);
  }
});

test("call-return lifecycle responders receive a run-scoped acknowledgement", () => {
  const runner = readFileSync(
    path.join(root, "Tests/Support/WireCompatibility/Lifecycle/Live/run-lifecycle-call-return.sh"),
    "utf8",
  );
  const peer = readFileSync(
    path.join(root, "Tests/Support/WireCompatibility/Reverse/coatyjs-core-consumer.js"),
    "utf8",
  );

  assert.match(runner, /ACK_BASENAME=/);
  assert.match(runner, /ACK_TOKEN=/);
  assert.match(runner, /-v "\$OUT:\/artifacts"/);
  assert.match(runner, /-e WIRE_PEER_ACK_FILE="\/artifacts\/\$ACK_BASENAME"/);
  assert.match(runner, /-e WIRE_PEER_ACK_TOKEN="\$ACK_TOKEN"/);
  assert.match(runner, /test -s "\$ACK_FILE"/);
  assert.match(peer, /scenario === "duplicate-reply"/);
  assert.match(peer, /scenario === "late-reply"/);
  assert.match(peer, /phase: "peer-ack"/);
});

test("wire CI summary prints evidence paths without shell substitution", () => {
  const workflow = readFileSync(
    path.join(root, ".github/workflows/wire-compatibility.yml"),
    "utf8",
  );
  const summaryLines = workflow
    .split("\n")
    .filter((line) => line.includes("CI run record:") || line.includes("Runner/owned-runtime diagnostics:"));

  assert.equal(summaryLines.length, 2);
  for (const line of summaryLines) {
    assert.equal((line.match(/\\`/g) ?? []).length, 2, line);
    assert.doesNotMatch(line, /(^|[^\\])`/);
  }
});
