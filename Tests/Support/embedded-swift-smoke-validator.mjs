// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

export const schemaVersion = 2;
export const expectedRunId = "embedded-swift-smoke-v2";
export const evidenceStages = Object.freeze([
  "setup", "build", "flash", "capture", "boot", "execute", "summary", "completion",
]);
export const maxDiagnosticLength = 256;
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

const recordStages = new Set(["boot", "execute", "summary", "completion"]);

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
  mixText(record.caseId); mixText(record.operation); mixText(record.stage); mixText(record.status);
  mixUInt32(record.counts?.passed ?? 0); mixUInt32(record.counts?.failed ?? 0);
  mixUInt32(previous);
  return hash >>> 0;
}

/** Creates a valid protocol record for focused host-side protocol tests. */
export function makeRecord(sequence, caseId, operation, status, previous, counts) {
  const stage = caseId === "boot" ? "boot" : caseId === "summary" ? "summary" : caseId === "completion" ? "completion" : "execute";
  const record = { schemaVersion, runId: expectedRunId, sequence, caseId, operation, stage, status };
  if (counts) record.counts = counts;
  record.checksum = checksum(record, previous);
  return record;
}

function boundedDiagnostic(value, fallback = "embedded evidence validation failed") {
  const diagnostic = typeof value === "string" && value.length > 0 ? value : fallback;
  return diagnostic.length <= maxDiagnosticLength
    ? diagnostic
    : `${diagnostic.slice(0, maxDiagnosticLength - 1)}…`;
}

/** Creates the stable failure shape consumed by embedded evidence runners. */
export function failureResult(stage, reason) {
  const diagnostic = boundedDiagnostic(reason);
  const stableStage = evidenceStages.includes(stage) ? stage : "capture";
  return { passed: false, stage: stableStage, diagnostic, reason: diagnostic };
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

  function reject(stage, reason) {
    if (!failure) failure = failureResult(stage, reason);
    return true;
  }

  function commonFailure(record) {
    if (!record || typeof record !== "object" || Array.isArray(record)) {
      return "malformed record";
    }
    if (record.schemaVersion !== schemaVersion || record.runId !== expectedRunId) {
      return "invalid schema identity";
    }
    if (!Number.isInteger(record.sequence) || record.sequence !== expectedSequence) {
      return "invalid sequence";
    }
    if (typeof record.caseId !== "string" || typeof record.operation !== "string") {
      return "invalid record identity";
    }
    if (!recordStages.has(record.stage)) return "invalid stage";
    if (typeof record.status !== "string") return "invalid status";
    if (!Number.isInteger(record.checksum) || record.checksum < 0 || record.checksum > 0xffffffff) {
      return "invalid checksum";
    }
    if (record.checksum !== checksum(record, previousChecksum)) return "checksum mismatch";
    return null;
  }

  function observe(line) {
    if (fatalFragments.some(fragment => line.includes(fragment))) return reject("capture", `fatal device output: ${line}`);
    if (!line.startsWith("{")) return false;
    let record;
    try { record = JSON.parse(line); } catch { return reject("capture", `malformed JSON record: ${line}`); }
    const commonError = commonFailure(record);
    if (commonError) return reject("capture", commonError);
    previousChecksum = record.checksum; expectedSequence += 1;

    if (record.caseId === "boot") {
      if (bootSeen || summary || completionSeen || record.operation !== "boot" || record.stage !== "boot" || record.status !== "started") return reject("boot", "unexpected reboot or invalid boot");
      bootSeen = true; return false;
    }
    if (expectedTests.has(record.caseId)) {
      if (!bootSeen || summary || completionSeen || record.operation !== "smokeCheck" || record.stage !== "execute") return reject("execute", "test record out of order");
      if (seenTests.has(record.caseId)) return reject("execute", `duplicate test record: ${record.caseId}`);
      if (record.status !== "passed") {
        if (typeof record.diagnostic !== "string" || record.diagnostic.length === 0 || record.diagnostic.length > maxDiagnosticLength) {
          return reject("execute", `failed test record: ${record.caseId}: missing or unbounded diagnostic`);
        }
        return reject("execute", record.diagnostic);
      }
      seenTests.add(record.caseId); return false;
    }
    if (record.caseId === "summary") {
      if (!bootSeen || summary || completionSeen || record.operation !== "summary" || record.stage !== "summary" || !["completed", "failed"].includes(record.status) || !validCounts(record.counts)) return reject("summary", "invalid summary record");
      if (record.status === "failed") return reject("summary", record.diagnostic ?? "summary reports failed execution checks");
      summary = record.counts; return false;
    }
    if (record.caseId === "completion") {
      if (!summary) return reject("summary", "missing summary record");
      if (completionSeen || record.operation !== "complete" || record.stage !== "completion" || !["completed", "failed"].includes(record.status) || !validCounts(record.counts) || record.counts.passed !== summary.passed || record.counts.failed !== summary.failed || record.finalChecksum !== record.checksum) return reject("completion", "invalid completion record");
      if (record.status === "failed") return reject("completion", record.diagnostic ?? "completion reports failed execution checks");
      completionMetrics = record.metrics ?? null;
      completionSeen = true; return true;
    }
    return reject("execute", `unknown case identifier: ${record.caseId}`);
  }

  function validCounts(counts) {
    return counts && Number.isInteger(counts.passed) && counts.passed >= 0 &&
      Number.isInteger(counts.failed) && counts.failed >= 0;
  }

  function result() {
    if (failure) return failure;
    if (!bootSeen) return failureResult("boot", "missing boot record");
    if (seenTests.size !== expectedTests.size) return failureResult("execute", "missing expected test records");
    if (!summary) return failureResult("summary", "missing summary record");
    if (!completionSeen) return failureResult("completion", "missing completion record");
    if (summary.failed !== 0 || summary.passed !== expectedTests.size) return failureResult("summary", "invalid summary counts");
    return {
      passed: true,
      reason: "all structured smoke records passed",
      metrics: completionMetrics,
    };
  }

  return { observe, result };
}
