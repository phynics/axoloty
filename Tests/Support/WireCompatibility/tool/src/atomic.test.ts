// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { atomicWriteFileSync, waitForFile } from "./atomic.js";

test("atomicWriteFileSync replaces an existing destination only with the full document", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-atomic-"));
  const destination = join(directory, "out.json");

  // The destination did not exist before the first write.
  atomicWriteFileSync(destination, "{\"a\":1}\n");
  assert.equal(readFileSync(destination, "utf8"), "{\"a\":1}\n");

  // A second write must replace the destination atomically, never leaving a
  // partial mixture of old and new content.
  atomicWriteFileSync(destination, "{\"b\":2}\n");
  assert.equal(readFileSync(destination, "utf8"), "{\"b\":2}\n");
});

test("atomicWriteFileSync leaves no temporary files behind", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-atomic-"));
  const destination = join(directory, "manifest.json");

  atomicWriteFileSync(destination, "payload\n");

  const leftovers = readdirSync(directory).filter((entry) => entry !== "manifest.json");
  assert.deepEqual(leftovers, []);
});

test("waitForFile resolves once a marker file appears", async () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-ready-"));
  const marker = join(directory, "ready");

  const pending = waitForFile(marker, 5, 10);
  setTimeout(() => writeFileSync(marker, "subscribed\n"), 20);

  await pending;
});

test("waitForFile rejects clearly when the marker never appears", async () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-ready-"));
  const marker = join(directory, "never-ready");

  await assert.rejects(waitForFile(marker, 0.05, 5), /did not appear within 0\.05s/);
});