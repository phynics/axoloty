// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { generateBundle, verifyBundle } from "./release-snapshots.mjs";

function capture(payload = "e30=") {
  return `${JSON.stringify({
    format: "coaty-wire-capture/v1",
    producer: { implementation: "fixture", version: "1.0.0" },
    scenario: "advertise",
    sequence: 1,
    mqtt: { topic: "coaty/advertise", qos: 0, retain: false, duplicate: false },
    payload: { encoding: "base64", bytes: payload },
    normalizationProfile: "coaty-wire/v1",
  })}\n`;
}

test("release bundle carries provenance and verifies content hashes", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-release-snapshot-"));
  const source = path.join(temporary, "source");
  const output = path.join(temporary, "output");
  const normalizationRules = path.join(temporary, "normalization-rules.json");
  fs.mkdirSync(path.join(source, "nested"), { recursive: true });
  fs.writeFileSync(path.join(source, "nested", "advertise.jsonl"), capture());
  fs.writeFileSync(normalizationRules, "{}\n");

  const manifest = generateBundle(source, output, {
    SOURCE_DATE_EPOCH: "0",
    AXOLOTY_IMAGE_IDENTITY: "sha256:test",
    AXOLOTY_NORMALIZATION_RULES: normalizationRules,
  });
  assert.equal(manifest.format, "axoloty-wire-snapshot-bundle/v1");
  assert.equal(manifest.generatedAt, "1970-01-01T00:00:00.000Z");
  assert.equal(manifest.provenance.imageIdentity, "sha256:test");
  assert.equal(manifest.captures[0].file, path.join("captures", "nested", "advertise.jsonl"));
  assert.deepEqual(verifyBundle(output), manifest);

  fs.appendFileSync(path.join(output, manifest.captures[0].file), "tampered");
  assert.throws(() => verifyBundle(output), /SHA-256 mismatch/);
  fs.rmSync(temporary, { recursive: true, force: true });
});
