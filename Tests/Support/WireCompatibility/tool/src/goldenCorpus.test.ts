// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { repositoryRootFromModule, renderGoldenCorpus } from "./goldenCorpus.js";

const goldenDir = path.join(
  repositoryRootFromModule(import.meta.url),
  "Tests/AxolotyTests/WireCompatibility/Golden",
);

test("checked-in goldens match the generator byte for byte", () => {
  const { files } = renderGoldenCorpus();
  for (const [name, contents] of files) {
    const checkedIn = fs.readFileSync(path.join(goldenDir, name));
    assert.ok(checkedIn.equals(contents), `${name} drifted; run npm run golden:generate`);
  }
});

test("the corpus covers every event family and field-presence variant", () => {
  const { manifest } = renderGoldenCorpus();
  const families = new Set(manifest.cases.map(goldenCase => goldenCase.family));
  assert.deepEqual(
    [...families].sort(),
    ["advertise", "associate", "call", "channel", "complete", "deadvertise", "discover", "ioState", "ioValue", "query", "resolve", "retrieve", "return", "update"],
  );
  for (const family of ["call", "channel", "complete", "discover", "query", "return"]) {
    assert.ok(
      manifest.cases.some(goldenCase => goldenCase.family === family && goldenCase.variant === "empty"),
      `${family} must include an all-optional-absent case`,
    );
  }
  assert.ok(manifest.cases.length >= 28);
});
