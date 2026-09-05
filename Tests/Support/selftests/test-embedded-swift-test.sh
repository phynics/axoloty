#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { makeRecord } from "./Tests/Support/embedded/embedded-swift-smoke-validator.mjs";
import { expectedEmbeddedSwiftTests, createEmbeddedSwiftTestValidator } from "./Tests/Support/embedded/embedded-swift-test-validator.mjs";
let previous = 0;
const validator = createEmbeddedSwiftTestValidator();
let sequence = 0;
const observe = record => { assert.equal(validator.observe(JSON.stringify(record)), false); previous = record.checksum; };
observe(makeRecord(sequence++, "boot", "boot", "started", previous));
for (const id of expectedEmbeddedSwiftTests) observe(makeRecord(sequence++, id, "smokeCheck", "passed", previous));
const summary = makeRecord(sequence++, "summary", "summary", "completed", previous, { passed: expectedEmbeddedSwiftTests.size, failed: 0 });
observe(summary);
const completion = makeRecord(sequence, "completion", "complete", "completed", previous, { passed: expectedEmbeddedSwiftTests.size, failed: 0 });
completion.finalChecksum = completion.checksum;
completion.metrics = { hotPathAllocations: 0 };
assert.equal(validator.observe(JSON.stringify(completion)), true);
assert.deepEqual(validator.result(), {
  passed: true,
  reason: "all structured smoke records passed",
  metrics: { hotPathAllocations: 0 },
});
JS
echo "embedded-swift-test validator self-test: OK"
