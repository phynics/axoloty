// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/** The exact smoke checks emitted by the ESP32-C6 firmware. */
export const expectedSmokeTests = new Set([
  "topicParse:ADV",
  "topicParse:DAD",
  "topicParse:DSC",
  "topicParse:RSV",
  "topicParse:CHN",
  "topicParse:ASC",
  "topicParse:IOV",
  "topicParse:raw",
  "topicParse:filter",
  "dtoDecode:advertise",
  "dtoDecode:uuid",
  "dtoDecode:int",
  "dtoDecode:bool",
  "dtoDecode:missingField",
  "malformed:truncated",
  "malformed:empty",
  "malformed:invalidUUID",
  "uuid16:parseValid",
  "uuid16:parseInvalid",
  "uuid16:zero",
  "config:payloadMax512",
  "config:topicMax128",
  "config:maxSubscribers8",
  "config:maxFamilyEntries16",
]);

const fatalFragments = ["Guru Meditation", "abort()", "Backtrace:"];

/**
 * Validates the structured JSON Lines protocol emitted by the Embedded Swift
 * smoke firmware.
 *
 * Boot ROM output is intentionally ignored. Every line beginning with `{`
 * must be a valid expected protocol record.
 */
export function createEmbeddedSwiftSmokeValidator() {
  const seenTests = new Set();
  let bootSeen = false;
  let summary = null;
  let completionSeen = false;
  let failure = null;

  function reject(reason) {
    if (!failure) failure = reason;
    return true;
  }

  function observe(line) {
    if (fatalFragments.some(fragment => line.includes(fragment))) {
      return reject(`fatal device output: ${line}`);
    }
    if (!line.startsWith("{")) return false;

    let record;
    try {
      record = JSON.parse(line);
    } catch {
      return reject(`malformed JSON record: ${line}`);
    }

    if (record.phase === "boot") {
      if (record.status !== "started") return reject("invalid boot record");
      if (bootSeen || summary || completionSeen) return reject("unexpected reboot record");
      bootSeen = true;
      return false;
    }

    if (Object.hasOwn(record, "test")) {
      if (!bootSeen || summary || completionSeen) return reject("test record outside test phase");
      if (typeof record.test !== "string" || !expectedSmokeTests.has(record.test)) {
        return reject(`unexpected test record: ${record.test}`);
      }
      if (seenTests.has(record.test)) return reject(`duplicate test record: ${record.test}`);
      if (record.status !== "passed") return reject(`failed test record: ${record.test}`);
      seenTests.add(record.test);
      return false;
    }

    if (Object.hasOwn(record, "tests")) {
      if (!bootSeen || summary || completionSeen) return reject("summary record out of order");
      if (!record.tests || !Number.isInteger(record.tests.passed) || !Number.isInteger(record.tests.failed)) {
        return reject("invalid summary record");
      }
      summary = record.tests;
      return false;
    }

    if (record.phase === "smoke") {
      if (record.status === "failed") return reject("firmware reported smoke failure");
      if (record.status !== "completed") return reject("invalid smoke completion record");
      if (!summary || completionSeen) return reject("completion record out of order");
      completionSeen = true;
      return true;
    }

    return reject("unexpected JSON record");
  }

  function result() {
    if (failure) return { passed: false, reason: failure };
    if (!bootSeen) return { passed: false, reason: "missing boot record" };
    if (!completionSeen) return { passed: false, reason: "missing completion record" };
    if (seenTests.size !== expectedSmokeTests.size) {
      const missing = [...expectedSmokeTests].filter(name => !seenTests.has(name));
      return { passed: false, reason: `missing expected test records: ${missing.join(",")}` };
    }
    if (summary.failed !== 0 || summary.passed !== expectedSmokeTests.size) {
      return { passed: false, reason: "summary counts do not match passed test records" };
    }
    return { passed: true, reason: "all structured smoke records passed" };
  }

  return { observe, result };
}
