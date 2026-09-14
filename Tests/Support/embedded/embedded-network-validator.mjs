// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { createEmbeddedSwiftSmokeValidator, expectedSmokeTests } from "./embedded-swift-smoke-validator.mjs";
import { expectedVectorTests } from "./embedded-swift-test-validator.mjs";
import { resolveEmbeddedCorpusManifest } from "./embedded-corpus-manifest.mjs";

const manifest = resolveEmbeddedCorpusManifest();
const corpus = ["topicParse", "dtoDecode", "dtoEncode", "combined", "borrowed", "topicBuild"];
export const expectedNetworkTests = new Set([
  ...expectedSmokeTests, ...expectedVectorTests,
  ...manifest.cases.flatMap(c => corpus.map(operation => `corpus:${c.id}:${operation}`)),
  "network:wifi", "network:ip", "network:mqttConnect", "network:subscribe",
  "network:lastWillConfigured", "network:reconnect",
  "network:publish", "network:receive", "network:disconnect",
  "network:rejectOutOfOrder", "network:rejectOversize",
]);

/** Creates the strict validator for the configured network firmware stream. */
export function createEmbeddedNetworkValidator() {
  return createEmbeddedSwiftSmokeValidator(expectedNetworkTests);
}
