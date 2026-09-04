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

test("canonical contract contains no retired zero-test gates", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const retired = new Set(["integration-tests", "logging-global"]);
  assert.deepEqual(document.nodes.filter(node => retired.has(node.id)), []);
  assert.equal(document.tiers.some(tier => tier.id === "integration"), false);
  assert.equal(document.requiredGates.some(gate => retired.has(gate)), false);
  assert.equal(document.releaseGates.includes("integration"), false);
  for (const plan of ["checkpoint", "checkpoint-hardware"]) {
    assert.equal(document.plans[plan].nodes.some(node => retired.has(node)), false, plan);
  }
});

test("package CI checks use stable isolated scratch paths", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const expected = new Map([
    ["repository-authority", ".build/tooling"],
    ["g3-object-model-tests", ".build/packages/axoloty-object-model"],
    ["g3-object-macros-tests", ".build/packages/axoloty-object-macros"],
    ["g3-coaty-models-tests", ".build/packages/axoloty-coaty-models"],
    ["g4-protocol-lifecycle", ".build/packages/axoloty-protocol"],
    ["g4-static-runtime", ".build/packages/axoloty-static-runtime"],
  ]);

  for (const [id, scratchPath] of expected) {
    const candidate = document.nodes.find(node => node.id === id);
    assert.ok(candidate, `missing node: ${id}`);
    const args = candidate.command.arguments;
    assert.equal(args[args.indexOf("--scratch-path") + 1], scratchPath, id);
  }
  assert.equal(new Set(expected.values()).size, expected.size);

  const protocolChecker = fs.readFileSync(path.join(root, "Tests/Support/check-axoloty-protocol-package.sh"), "utf8");
  assert.match(protocolChecker, /--scratch-path "\$root\/\.build\/packages\/axoloty-protocol"/);
  assert.match(protocolChecker, /--target AxolotyProtocol/);
  assert.doesNotMatch(protocolChecker, /--product AxolotyProtocol/);
  const objectChecker = fs.readFileSync(path.join(root, "Tests/Support/check-axoloty-object-model-package.sh"), "utf8");
  assert.match(objectChecker, /--scratch-path "\$root\/\.build\/packages\/axoloty-object-model"/);
  assert.match(objectChecker, /--scratch-path "\$root\/\.build\/packages\/axoloty-coaty-models"/);
  assert.match(objectChecker, /--target AxolotyObjectModel/);
  assert.match(objectChecker, /--target AxolotyCoatyModels/);
  assert.doesNotMatch(objectChecker, /--product (?:AxolotyObjectModel|AxolotyCoatyModels)/);
});

test("G6 public product builds are offline-only", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const inventory = document.nodes.find(node => node.id === "g6-public-products");
  const build = document.nodes.find(node => node.id === "g6-public-products-build");

  assert.ok(inventory);
  assert.equal(inventory.ci, true);
  assert.equal(inventory.command.environment.AXOLOTY_G6_PRODUCT_BUILD, "0");

  assert.ok(build);
  assert.equal(build.local, true);
  assert.equal(build.ci, false);
  assert.equal(build.command.environment.AXOLOTY_G6_PRODUCT_BUILD, "1");
  assert.ok(document.tiers.find(tier => tier.id === "g6-non-divergence").nodes.includes(build.id));
  assert.ok(document.plans.checkpoint.nodes.includes(build.id));
  assert.equal(document.plans["checkpoint-hardware"].inherits, "checkpoint");
});

test("validator rejects retired canonical nodes and filters if reintroduced", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const template = document.nodes.find(node => node.id === "build");
  for (const [id, filter] of [["integration-tests", "MQTTNIOClientTests"], ["logging-global", "LogManagerTests"]]) {
    document.nodes.push({
      ...template,
      id,
      filter,
      command: { ...template.command, arguments: [...template.command.arguments, "--filter", filter] },
    });
  }
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.includes("integration-tests: retired canonical node must not be declared"));
  assert.ok(errors.includes("logging-global: retired canonical node must not be declared"));
  assert.ok(errors.includes('integration-tests: retired test filter "MQTTNIOClientTests" must not be declared'));
  assert.ok(errors.includes('logging-global: retired test filter "LogManagerTests" must not be declared'));
});

test("retired make test alias stays removed so no stale integration tier can return", () => {
  const makefile = fs.readFileSync(path.join(root, "Makefile"), "utf8");
  assert.doesNotMatch(makefile, /^test:\s*$/m);
  assert.doesNotMatch(makefile, /^test:\s*TIER=integration\s*$/m);
  for (const filter of ["MQTTNIOClientTests", "DecentralizedLoggingTest", "LogManagerTests"]) {
    assert.doesNotMatch(makefile, new RegExp(`(?:--filter|\\|)\\s*[^"]*${filter}`), filter);
  }
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

test("G4 runtime filters are disjoint and use their owning Swift packages", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const node = id => document.nodes.find(candidate => candidate.id === id);
  const hostNodes = [node("g4-runtime-definition"), node("g4-host-runtime"), node("g4-runtime-concurrency")];
  const hostTests = [
    "mqttUUIDFormattingPreservesAllBytes", "identityStartupTopicIsFiltered", "builderEndpointProvenance",
    "builderFinishesHandlers", "rejectsInvalidNamespaceBytes", "definitionBoundsNamespaceForGeneratedTopics",
    "definitionBoundsEventStreams", "failedModuleRegistrationIsAtomic", "nestedDuplicateModuleKeyIsAtomic", "duplicateModuleKeyIsAtomic", "rejectsBeforeStart",
    "acceptsLocalOperation", "callOperationNameReachesTransportAction", "channelIdentifierReachesTransportAction",
    "multiActionDispatchReservationIsAtomic", "advertiseVariantsDoNotDuplicateRuntimeEvents", "channelRejectsMissingIdentifier",
    "defaultRequestUsesMonotonicClock", "unlimitedDiscoverCanBeCanceled", "rejectsInvalidCallOperationNames",
    "rejectsInvalidResponderOperationNames", "rejectsNonCallOperationFilters", "advertiseSelectorMatchesPayloadObjectType",
    "lifecycleOrdering", "postStartTransportFailureEntersReconnect", "queuesOfflineOneWayPublication", "stopDrainsOutboundPump",
  ];

  for (const testName of hostTests) {
    assert.equal(hostNodes.filter(candidate => candidate.filter.includes(testName)).length, 1, `${testName} must have one G4 owner`);
  }
  assert.equal(new Set(hostNodes.map(candidate => candidate.filter)).size, hostNodes.length);
  assert.equal(hostNodes.some(candidate => candidate.filter.includes("AxolotyStaticRuntimeTests")), false);

  const packageAssertions = [
    ["g4-protocol-lifecycle", "Packages/AxolotyProtocol", "ProtocolFoundationTests|ProtocolProcessorTests"],
    ["g4-static-runtime", "Packages/AxolotyStaticRuntime", "StaticRuntimeTests|StaticTypedIoTests"],
  ];
  for (const [id, packagePath, filter] of packageAssertions) {
    const candidate = node(id);
    const args = candidate.command.arguments;
    assert.equal(args[args.indexOf("--package-path") + 1], packagePath, `${id} must invoke its owning package`);
    assert.equal(candidate.filter, filter);
    assert.equal(args.includes("--product"), false, `${id} must run tests, not request a product`);
  }
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

test("validator requires repository authority tests in the tooling filter", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const node = document.nodes.find(candidate => candidate.id === "test-tooling");
  node.filter = node.filter.split("|").filter(suite => suite !== "RepositoryAuthorityTests").join("|");
  node.command.arguments[node.command.arguments.indexOf("--filter") + 1] = node.filter;
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.includes("test-tooling must select RepositoryAuthorityTests"));
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

test("validator requires every maintained self-test in a canonical verify gate", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const omitted = "Tests/Support/package-layout.test.mjs";
  document.requiredGates = document.requiredGates.filter(id => id !== "support-package-layout-self-test");
  const node = document.nodes.find(candidate => candidate.id === "support-package-layout-self-test");
  node.required = false;
  node.local = false;
  node.ci = false;
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.includes(`selfTest ${omitted}: canonical verify has no required gate invoking it`));
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

test("validator rejects a plan without an absolute deadline", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  delete document.plans.verify.timeoutSeconds;
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.includes("plan verify: timeoutSeconds must be a positive integer"));
});

test("validator enforces the canonical CI plan budget below the job deadline", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.plans.verify.timeoutSeconds = 5400;
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.includes("plan verify: timeoutSeconds must be 4800 seconds (80 minutes), below the 90-minute CI job deadline"));
});

test("validator rejects required release tier absent from releaseGates", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.releaseGates = document.releaseGates.filter(gate => gate !== "wire-live");
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.some(error => error.includes('required tier "wire-live" is absent from releaseGates')));
});

test("validator rejects mandatory release tier omitted from the checkpoint plan", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  const objectModelNodes = new Set(document.tiers.find(tier => tier.id === "g3-object-model").nodes);
  for (const plan of ["checkpoint", "checkpoint-hardware"]) {
    document.plans[plan].nodes = document.plans[plan].nodes.filter(
      node => !objectModelNodes.has(node)
    );
  }
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.some(error => error.includes('required release tier "g3-object-model" is not covered by the checkpoint plan')));
});

test("validator accepts an intentionally attestable wire-live gate", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.plans.checkpoint.nodes = document.plans.checkpoint.nodes.filter(
    node => node !== "wire-capture-manifest"
  );
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.equal(errors.some(error => error.includes("wire-live")), false);
});

test("validator resolves checkpoint-hardware inheritance", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.plans["checkpoint-hardware"].nodes = ["checkpoint-hardware-smoke"];
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.equal(errors.some(error => error.includes("omits inherited node")), false);
});

test("validator rejects a hardware plan that stops inheriting checkpoint", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.plans["checkpoint-hardware"].inherits = "offline";
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.some(error => error.includes("must inherit checkpoint")));
});

test("validator rejects checkpoint plan inheritance cycles", () => {
  const document = JSON.parse(fs.readFileSync(path.join(root, "Tests/Support/test-tiers.json"), "utf8"));
  document.plans.offline.inherits = "checkpoint";
  document.plans.checkpoint.inherits = "offline";
  const errors = validate(document, {
    makeTargets: parseMakeTargets(path.join(root, "Makefile")),
    discoveredSelfTests: [],
    exists: () => true,
  });
  assert.ok(errors.some(error => error.includes("plan inheritance cycle")));
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
