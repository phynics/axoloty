// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildManifest } from "./manifest.js";

const CAPTURE_RECORD = {
  format: "coaty-wire-capture/v1",
  producer: { implementation: "coatyswift-modern", version: "current" },
  scenario: "duplicate-reply",
  sequence: 1,
};

test("buildManifest indexes captures and excludes application-state logs", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-manifest-"));
  writeFileSync(
    join(directory, "axoloty-duplicate-reply.jsonl"),
    JSON.stringify(CAPTURE_RECORD) + "\n",
  );
  writeFileSync(
    join(directory, "axoloty-duplicate-reply.application.jsonl"),
    JSON.stringify({ state: "ready", scenario: "duplicate-reply" }) + "\n",
  );

  const manifest = buildManifest(directory);

  assert.equal(manifest.captures.length, 1);
  const entry = manifest.captures[0];
  assert.ok(entry);
  assert.equal(entry.file, "axoloty-duplicate-reply.jsonl");
  assert.equal(entry.recordCount, 1);
  assert.equal(entry.scenario, "duplicate-reply");
});

test("buildManifest rejects a directory with no capture files", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-manifest-empty-"));
  writeFileSync(
    join(directory, "axoloty-duplicate-reply.application.jsonl"),
    JSON.stringify({ state: "ready", scenario: "duplicate-reply" }) + "\n",
  );

  assert.throws(() => buildManifest(directory), /no JSONL captures found/);
});
