// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { latestManifest, summaryMarkdown } from "./fuzz-summary.mjs";

test("fuzz summary selects the latest manifest and preserves fields", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-fuzz-"));
  fs.mkdirSync(path.join(root, "fuzz-001"));
  fs.mkdirSync(path.join(root, "fuzz-002"));
  fs.writeFileSync(path.join(root, "fuzz-001", "manifest.json"), "{}");
  fs.writeFileSync(path.join(root, "fuzz-002", "manifest.json"), "{}");
  assert.equal(latestManifest(root), path.join(root, "fuzz-002", "manifest.json"));
  assert.match(summaryMarkdown({ status: "passed", seeds: ["1", "2"], iterations: 3, repetitions: 4, durationSeconds: 5, failedCases: 0 }), /Seeds: `1,2`/);
  fs.rmSync(root, { recursive: true, force: true });
});
