// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { verifyLifecycleBehavior } from "./lifecycle.js";

function fixture(directory: string, states: string[], payloads: string[]): [string, string] {
  const application = join(directory, "application.jsonl");
  const capture = join(directory, "capture.jsonl");
  writeFileSync(application, states.map((state) => JSON.stringify({ state, at: "2026-08-22T00:00:00.000Z" })).join("\n") + "\n");
  writeFileSync(capture, payloads.map((payload, index) => JSON.stringify({
    capturedAt: "2026-08-22T00:00:01.000Z",
    mqtt: { topic: "coaty/3/test/ADV/00000000-0000-0000-0000-000000000000" },
    payload: { encoding: "base64", bytes: Buffer.from(payload).toString("base64") },
    sequence: index + 1,
  })).join("\n") + "\n");
  return [application, capture];
}

test("lifecycle verifier requires the offline publication state and order", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-lifecycle-verifier-"));
  const [application, capture] = fixture(directory,
    ["ready", "offline", "published-offline", "reconnected", "done"],
    ['{"name":"first"}', '{"name":"second"}']);
  assert.doesNotThrow(() => verifyLifecycleBehavior("offline-queueing", application, capture));
});

test("lifecycle verifier rejects a fabricated duplicate result", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-lifecycle-verifier-"));
  const [application, capture] = fixture(directory,
    ["ready", "accepted", "ignored", "done"],
    ['{"variant":"original"}']);
  assert.throws(() => verifyLifecycleBehavior("duplicate-reply", application, capture), /original and duplicate/);
});

test("lifecycle verifier recognizes filtered Coaty Advertise routes", () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-lifecycle-verifier-"));
  const application = join(directory, "application.jsonl");
  const capture = join(directory, "capture.jsonl");
  writeFileSync(application, [
    "ready",
    "offline",
    "reconnected",
    "probe-received",
    "done",
  ].map((state) => JSON.stringify({ state })).join("\n") + "\n");
  writeFileSync(capture, JSON.stringify({
    mqtt: { topic: "coaty/3/test/ADV:CoatyObject/11111111-1111-4111-8111-111111111111" },
    payload: { encoding: "base64", bytes: Buffer.from('{"objectType":"com.coaty.test.WireFixture"}').toString("base64") },
  }) + "\n");
  assert.doesNotThrow(() => verifyLifecycleBehavior("reconnect-resubscribe", application, capture));
});
