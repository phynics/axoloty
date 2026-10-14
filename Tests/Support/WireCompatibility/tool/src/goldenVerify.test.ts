// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

import { repositoryRootFromModule } from "./goldenCorpus.js";
import { verifyGoldenCorpus } from "./goldenVerify.js";

const goldenDir = path.join(
  repositoryRootFromModule(import.meta.url),
  "Tests/AxolotyTests/WireCompatibility/Golden",
);

test("independent cbor-x decode matches every golden JSON", () => {
  assert.deepEqual(verifyGoldenCorpus(goldenDir), []);
});

test("the verifier rejects a float that is not the shortest lossless width", () => {
  // `1.5` encoded as float64 instead of float32 still decodes to `1.5`, so the
  // independent decode alone would accept it. The re-encode check must catch
  // the non-shortest form.
  const source = fs.readFileSync(path.join(goldenDir, "iovalue-float-single.cbor"));
  const tampered = Buffer.concat([
    source.subarray(0, source.length - 5),
    Buffer.from([0xfb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
  ]);
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "golden-verify-"));
  try {
    fs.cpSync(goldenDir, tempDir, { recursive: true });
    fs.writeFileSync(path.join(tempDir, "iovalue-float-single.cbor"), tampered);
    const problems = verifyGoldenCorpus(tempDir);
    assert.ok(
      problems.some(problem => problem.includes("iovalue-float-single")),
      `expected a reported problem, got ${JSON.stringify(problems)}`,
    );
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
