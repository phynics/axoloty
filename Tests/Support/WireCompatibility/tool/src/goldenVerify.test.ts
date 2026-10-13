// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
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
