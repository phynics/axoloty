// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import path from "node:path";

import { repositoryRootFromModule } from "./goldenCorpus.js";
import { verifyGoldenCorpus } from "./goldenVerify.js";

const goldenDir =
  process.argv[2] ??
  path.join(repositoryRootFromModule(import.meta.url), "Tests/AxolotyTests/WireCompatibility/Golden");

const problems = verifyGoldenCorpus(goldenDir);
if (problems.length > 0) {
  for (const problem of problems) console.error(`golden CBOR verification error: ${problem}`);
  process.exitCode = 1;
} else {
  console.log(`PASS: independent cbor-x decode matched every golden in ${goldenDir}`);
}
