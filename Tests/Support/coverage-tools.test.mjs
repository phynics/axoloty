// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import test from "node:test";
import { aggregate, evaluateCoverage, extractCoverage, extractLineCoverage, parseChangedLines, renderCoverageMarkdown, summarizeCoverage } from "./coverage-tools.mjs";

const coverage = {
  data: [{ files: [
    { filename: "/workspace/Source/Foo.swift", summary: { lines: { count: 4, covered: 3 } }, segments: [[1, 1, 1, true, true, false], [2, 1, 0, true, true, false]] },
    { filename: "/workspace/Tests/FooTests.swift", summary: { lines: { count: 9, covered: 9 } }, segments: [] },
  ] }],
};

test("extracts only production source coverage", () => {
  assert.deepEqual(extractCoverage(coverage), { "Source/Foo.swift": { count: 4, covered: 3 } });
  assert.deepEqual(aggregate(extractCoverage(coverage)), { covered: 3, count: 4, percent: 75 });
});

test("aggregate ratchet applies one percentage point policy", () => {
  assert.deepEqual(evaluateCoverage({ foo: { count: 100, covered: 89 } }, { _aggregate: { percent: 90 } }), []);
  assert.equal(evaluateCoverage({ foo: { count: 100, covered: 88 } }, { _aggregate: { percent: 90 } }).length, 1);
});

test("parses added diff lines and ignores deletions", () => {
  const changed = parseChangedLines("+++ b/Source/Foo.swift\n@@ -1,2 +1,3 @@\n old\n+new\n-gone\n same\n");
  assert.deepEqual([...changed["Source/Foo.swift"]], [2]);
});

test("summarizes changed line coverage", () => {
  assert.deepEqual(extractLineCoverage(coverage)["Source/Foo.swift"], { 1: true, 2: false });
  const summary = summarizeCoverage(coverage, "+++ b/Source/Foo.swift\n@@ -1 +1,2 @@\n old\n+new\n", { _aggregate: { percent: 80 }, files: {} });
  assert.deepEqual(summary.changed, { covered: 0, count: 1, percent: 0 });
  assert.match(renderCoverageMarkdown(summary), /Source coverage/);
});
