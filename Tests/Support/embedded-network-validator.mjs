// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import { createEmbeddedSwiftSmokeValidator, expectedSmokeTests } from "./embedded-swift-smoke-validator.mjs";
import { expectedVectorTests } from "./embedded-swift-test-validator.mjs";

const manifest = JSON.parse(fs.readFileSync(new URL("../../Benchmarks/Corpus/manifest.json", import.meta.url), "utf8"));
const corpus = ["topicParse", "dtoDecode", "dtoEncode", "combined", "borrowed", "topicBuild"];
export const expectedNetworkTests = new Set([
  ...expectedSmokeTests, ...expectedVectorTests,
  ...manifest.cases.flatMap(c => corpus.map(operation => `corpus:${c.id}:${operation}`)),
  "network:wifi", "network:ip", "network:mqttConnect", "network:subscribe",
  "network:publish", "network:receive", "network:disconnect",
]);

/** Creates the strict validator for the configured network firmware stream. */
export function createEmbeddedNetworkValidator() {
  return createEmbeddedSwiftSmokeValidator(expectedNetworkTests);
}
