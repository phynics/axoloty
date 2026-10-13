// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import path from "node:path";

import { repositoryRootFromModule, writeGoldenCorpus } from "./goldenCorpus.js";

const goldenDir =
  process.argv[2] ??
  path.join(repositoryRootFromModule(import.meta.url), "Tests/AxolotyTests/WireCompatibility/Golden");

const manifest = writeGoldenCorpus(goldenDir);
console.log(`wrote ${manifest.cases.length} golden cases to ${goldenDir}`);
