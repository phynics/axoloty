// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";

const source = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const outputDirectory = process.argv[3];

function writeFixture(name, base, mutate) {
  const fixture = structuredClone(base);
  mutate(fixture);
  fs.writeFileSync(`${outputDirectory}/${name}.json`, `${JSON.stringify(fixture)}\n`);
}

function approvedBase() {
  const fixture = structuredClone(source);
  fixture.approvalStatus = "approved";
  for (const entry of Object.values(fixture.environments.host.latency)) {
    Object.assign(entry, { p50ns: 1000, p95ns: 2000, budgetP50ns: 1500, budgetP95ns: 3000, status: "ok" });
  }
  for (const entry of Object.values(fixture.environments.host.binarySize)) {
    Object.assign(entry, { unstrippedBytes: 100000, strippedBytes: 50000, status: "ok" });
  }
  for (const environment of ["host", "esp32c6"]) {
    for (const key of Object.keys(fixture.environments[environment].fingerprint)) {
      fixture.environments[environment].fingerprint[key] = "test-fingerprint-value";
    }
  }
  const device = fixture.environments.esp32c6;
  device.sourceRun = "issue-322-embedded-swift-run-1";
  device.resources.sustainedRate.capacityHeadroomMsgPerS = 130;
  device.resources.largestFreeBlock = { measured: 200000, budgetMin: 160000, unit: "bytes" };
  device.resources.fragmentation = { measured: 0, budgetMax: 5, unit: "percent" };
  device.resources.data = { measured: 10000, budgetMax: 12000, unit: "bytes" };
  device.resources.bss = { measured: 5000, budgetMax: 6000, unit: "bytes" };
  device.resources.iram = { measured: 2000, budgetMax: 2500, unit: "bytes" };
  device.hotPathAllocations.measured = 0;
  return fixture;
}

fs.writeFileSync(`${outputDirectory}/approved-base.json`, `${JSON.stringify(approvedBase())}\n`);
const mutations = {
  "01-missing-moduleApiVersion": (m) => delete m.moduleApiVersion,
  "04-csurrogate-approved": (m) => { m.historicalEvidence["esp32c6-c-surrogate"].approvalEligible = true; },
  "05-no-p95-headroom": (m) => { m.environments.esp32c6.latency.topicParse.budgetP95us = 2; },
  "09-missing-entry-gate": (m) => { m.phase4EntryEvidenceGates.pop(); },
  "10-over-limit-not-rejected": (m) => { m.environments.esp32c6.sizeLimits.maxPayloadSize.overLimitRejected = false; },
  "11-completion-gates-too-few": (m) => { m.phase4CompletionGates.pop(); },
  "12-invalid-approval-status": (m) => { m.approvalStatus = "approved-but-todo"; },
  "13-wire-hostdeps-nonempty": (m) => { m.environments.host.dependencyClosure.AxolotyWireConsumer.hostDeps = ["mqtt-nio"]; },
  "14-partition-unsafe": (m) => { const flash = m.environments.esp32c6.resources.flashImage; flash.budgetMax = flash.partitionLimitBytes; },
  "02-approved-host-latency-pending": (m) => { m.environments.host.latency.topicParse.status = "pending-baseline"; },
  "03-approved-host-binarysize-pending": (m) => { m.environments.host.binarySize.AxolotyWireConsumer.status = "pending-baseline"; },
  "06-approved-missing-largestfreeblock": (m) => { delete m.environments.esp32c6.resources.largestFreeBlock; },
  "07-approved-missing-source-run": (m) => { m.environments.esp32c6.sourceRun = null; },
  "08-approved-no-rate-capacity": (m) => { m.environments.esp32c6.resources.sustainedRate.capacityHeadroomMsgPerS = 100; },
};

for (const [name, mutate] of Object.entries(mutations)) {
  const base = name.startsWith("0") && Number(name.slice(0, 2)) >= 2 && Number(name.slice(0, 2)) <= 8
    ? approvedBase()
    : source;
  writeFixture(name, base, mutate);
}
