// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { generateBundle, verifyBundle } from "./fixture-bundle.mjs";

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

test("fixture bundle carries provenance and verifies content hashes", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-fixture-bundle-"));
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
    AXOLOTY_FIXTURE_BUNDLE_ROOT: temporary,
  });
  assert.equal(manifest.format, "axoloty-fixture-bundle/v1");
  assert.equal(manifest.evidence.type, "fixture-bundle");
  assert.equal(manifest.evidence.mode, "offline");
  assert.equal(manifest.evidence.live, false);
  assert.equal(manifest.generatedAt, "1970-01-01T00:00:00.000Z");
  assert.equal(manifest.provenance.imageIdentity, "sha256:test");
  assert.equal(manifest.captures[0].file, path.join("captures", "nested", "advertise.jsonl"));
  assert.deepEqual(verifyBundle(output), manifest);

  fs.appendFileSync(path.join(output, manifest.captures[0].file), "tampered");
  assert.throws(() => verifyBundle(output), /SHA-256 mismatch/);
  fs.rmSync(temporary, { recursive: true, force: true });
});

test("fixture bundle rejects destructive and overlapping outputs", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-fixture-safety-"));
  const source = path.join(temporary, "source");
  fs.mkdirSync(source);
  const environment = { AXOLOTY_FIXTURE_BUNDLE_ROOT: temporary };

  assert.throws(() => generateBundle(source, temporary, environment), /must be a child/);
  assert.throws(() => generateBundle(source, path.join(source, "output"), environment), /must not overlap/);
  assert.ok(fs.existsSync(source));
  fs.rmSync(temporary, { recursive: true, force: true });
});

test("fixture bundle rejects manifests that claim live evidence", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "axoloty-fixture-live-reject-"));
  const source = path.join(temporary, "source");
  const output = path.join(temporary, "output");
  const normalizationRules = path.join(temporary, "normalization-rules.json");
  fs.mkdirSync(source, { recursive: true });
  fs.writeFileSync(path.join(source, "advertise.jsonl"), capture());
  fs.writeFileSync(normalizationRules, "{}\n");
  const environment = {
    AXOLOTY_NORMALIZATION_RULES: normalizationRules,
    AXOLOTY_FIXTURE_BUNDLE_ROOT: temporary,
  };
  const manifest = generateBundle(source, output, environment);

  manifest.evidence = { type: "fixture-bundle", mode: "offline", live: true };
  fs.writeFileSync(path.join(output, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  assert.throws(() => verifyBundle(output), /must declare fixture-only offline evidence/);

  fs.writeFileSync(path.join(output, "manifest.json"), JSON.stringify(manifest, null, 2).replace('"live": true', '"live": false') + "\n");
  assert.doesNotThrow(() => verifyBundle(output));
  fs.rmSync(temporary, { recursive: true, force: true });
});
