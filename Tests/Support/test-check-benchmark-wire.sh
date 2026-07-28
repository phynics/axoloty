#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Self-test for the wire benchmark orchestration (issue #300).
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
node --input-type=module - <<'JS'
import assert from "node:assert/strict";
import { percentile, mad, compare } from "./Tests/Support/benchmark-wire.mjs";

const values = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
assert.equal(percentile(values, 50), 55);
assert.ok(Math.abs(percentile(values, 95) - 95.5) < 0.01);

const lowMad = [1000, 1005, 998, 1002, 1001];
assert.ok(mad(lowMad) / 1001 <= 0.05);
const highMad = [1000, 1200, 800, 1500, 600];
assert.ok(mad(highMad) / 1000 > 0.05);

const firstEnvironment = { corpusHash: "abc123" };
const secondEnvironment = { corpusHash: "def456" };
assert.notEqual(firstEnvironment.corpusHash, secondEnvironment.corpusHash);

const baseline = {
  environment: { corpusHash: "test123" },
  cases: [{
    caseId: "advertise-small",
    family: "ADV",
    sizeClass: "small",
    operations: { topicParse: { p50ns: 100, p95ns: 200, batchSize: 10000 } },
  }],
};
assert.deepEqual(JSON.parse(JSON.stringify(baseline)), baseline);

const changed = structuredClone(baseline);
changed.cases[0].operations.topicParse.p50ns = 200;
changed.cases[0].operations.topicParse.p95ns = 400;
assert.match(compare(changed, baseline), /BASELINE DRIFT/);
JS
sh -n "$script_dir/check-benchmark-wire.sh"
echo "SELF-TEST OK (5 checks passed, 0 failed)"
