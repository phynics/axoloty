// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

export const schemaVersion = 1;
export const expectedRunId = "embedded-swift-smoke-v1";
export const expectedSmokeTests = new Set([
  "topicParse:ADV", "topicParse:DAD", "topicParse:DSC", "topicParse:RSV",
  "topicParse:CHN", "topicParse:ASC", "topicParse:IOV", "topicParse:raw",
  "topicParse:filter", "dtoDecode:advertise", "dtoDecode:uuid", "dtoDecode:int",
  "dtoDecode:bool", "dtoDecode:missingField", "malformed:truncated", "malformed:empty",
  "malformed:invalidUUID", "uuid16:parseValid", "uuid16:parseInvalid", "uuid16:zero",
  "config:payloadMax512", "config:topicMax128", "config:maxSubscribers8",
  "config:maxFamilyEntries16",
]);

const fatalFragments = ["Guru Meditation", "Task watchdog got triggered", "abort()", "Backtrace:"];

/** Computes the FNV-1a rolling checksum used by the firmware evidence protocol. */
export function checksum(record, previous = 0) {
  let hash = 2166136261;
  const bytes = value => new TextEncoder().encode(value);
  const mixByte = byte => { hash = Math.imul(hash ^ byte, 16777619) >>> 0; };
  const mixText = value => { for (const byte of bytes(value)) mixByte(byte); };
  const mixUInt32 = value => {
    for (let shift = 0; shift < 32; shift += 8) mixByte((value >>> shift) & 0xff);
  };
  mixUInt32(record.schemaVersion); mixText(record.runId); mixUInt32(record.sequence);
  mixText(record.caseId); mixText(record.operation); mixText(record.status);
  mixUInt32(record.counts?.passed ?? 0); mixUInt32(record.counts?.failed ?? 0);
  mixUInt32(previous);
  return hash >>> 0;
}

/** Creates a valid protocol record for focused host-side protocol tests. */
export function makeRecord(sequence, caseId, operation, status, previous, counts) {
  const record = { schemaVersion, runId: expectedRunId, sequence, caseId, operation, status };
  if (counts) record.counts = counts;
  record.checksum = checksum(record, previous);
  return record;
}

/** Validates structured JSON Lines emitted by the Embedded Swift smoke firmware. */
export function createEmbeddedSwiftSmokeValidator(expectedTests = expectedSmokeTests) {
  const seenTests = new Set();
  let expectedSequence = 0;
  let previousChecksum = 0;
  let bootSeen = false;
  let summary = null;
  let completionSeen = false;
  let completionMetrics = null;
  let failure = null;

  function reject(reason) { if (!failure) failure = reason; return true; }
  function validCommon(record) {
    return record.schemaVersion === schemaVersion && record.runId === expectedRunId &&
      Number.isInteger(record.sequence) && record.sequence === expectedSequence &&
      typeof record.caseId === "string" && typeof record.operation === "string" &&
      typeof record.status === "string" && Number.isInteger(record.checksum) &&
      record.checksum >= 0 && record.checksum <= 0xffffffff &&
      record.checksum === checksum(record, previousChecksum);
  }

  function observe(line) {
    if (fatalFragments.some(fragment => line.includes(fragment))) return reject(`fatal device output: ${line}`);
    if (!line.startsWith("{")) return false;
    let record;
    try { record = JSON.parse(line); } catch { return reject(`malformed JSON record: ${line}`); }
    if (!record || !validCommon(record)) return reject("invalid sequence, identity, or checksum");
    previousChecksum = record.checksum; expectedSequence += 1;

    if (record.caseId === "boot") {
      if (bootSeen || summary || completionSeen || record.operation !== "boot" || record.status !== "started") return reject("unexpected reboot or invalid boot");
      bootSeen = true; return false;
    }
    if (expectedTests.has(record.caseId)) {
      if (!bootSeen || summary || completionSeen || record.operation !== "smokeCheck") return reject("test record out of order");
      if (seenTests.has(record.caseId)) return reject(`duplicate test record: ${record.caseId}`);
      if (record.status !== "passed") return reject(`failed test record: ${record.caseId}`);
      seenTests.add(record.caseId); return false;
    }
    if (record.caseId === "summary") {
      if (!bootSeen || summary || completionSeen || record.operation !== "summary" || record.status !== "completed" || !validCounts(record.counts)) return reject("invalid summary record");
      summary = record.counts; return false;
    }
    if (record.caseId === "completion") {
      if (!summary || completionSeen || record.operation !== "complete" || record.status !== "completed" || !validCounts(record.counts) || record.counts.passed !== summary.passed || record.counts.failed !== summary.failed || record.finalChecksum !== record.checksum) return reject("invalid completion record");
      completionMetrics = record.metrics ?? null;
      completionSeen = true; return true;
    }
    return reject(`unknown case identifier: ${record.caseId}`);
  }

  function validCounts(counts) {
    return counts && Number.isInteger(counts.passed) && counts.passed >= 0 &&
      Number.isInteger(counts.failed) && counts.failed >= 0;
  }

  function result() {
    if (failure) return { passed: false, reason: failure };
    if (!bootSeen) return { passed: false, reason: "missing boot record" };
    if (!completionSeen) return { passed: false, reason: "missing completion record" };
    if (seenTests.size !== expectedTests.size) return { passed: false, reason: "missing expected test records" };
    if (!summary || summary.failed !== 0 || summary.passed !== expectedTests.size) return { passed: false, reason: "invalid summary counts" };
    return {
      passed: true,
      reason: "all structured smoke records passed",
      metrics: completionMetrics,
    };
  }
  return { observe, result };
}
