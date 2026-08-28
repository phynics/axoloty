// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import {
  expectedSmokeTests,
  createEmbeddedSwiftSmokeValidator,
  failureResult,
} from "./embedded-swift-smoke-validator.mjs";
import fs from "node:fs";

const manifest = JSON.parse(fs.readFileSync(
  new URL("../../Benchmarks/Corpus/manifest.json", import.meta.url),
  "utf8",
));
const corpusOperations = [
  "topicParse", "dtoDecode", "dtoEncode", "combined", "borrowed", "topicBuild",
];

/** Stable, deterministic on-device vector IDs grouped by behavior. */
export const expectedVectorTests = new Set([
  "writer:zero", "writer:one", "writer:minusOne", "writer:max", "writer:min",
  "topic:exact", "topic:underCapacity", "topic:overflow",
  "capacity:payload0", "capacity:payload1", "capacity:payload512",
  "capacity:payload2047", "capacity:payload2048", "capacity:payload2049", "capacity:topic0",
  "capacity:topic1", "capacity:topic256", "capacity:topic257",
  "malformed:truncation", "malformed:corruption", "malformed:utf8",
  "malformed:escape", "malformed:literal", "malformed:number",
  "malformed:missing", "malformed:unknown", "malformed:duplicate",
  "malformed:reordered", "malformed:trailing", "malformed:nesting",
  "borrowed:topicView", "borrowed:reader", "router:subscribe", "router:dispatch",
  "agent:identity", "agent:advertise", "agent:deadvertise", "agent:advertisedState",
  "agent:discover", "agent:discoverById", "agent:rejectWrongFilter",
  "agent:beginDiscover", "agent:boundedOutstanding",
  "agent:wrongCorrelation", "agent:resolve", "agent:duplicateResolve",
  "agent:beginTimedDiscover", "agent:resolveTimeout",
  "agent:fixedPublish", "agent:fixedDeadvertise",
  "agent:fixedDiscover", "agent:fixedResolve",
  "agent:callbackRejectUnsolicitedResolve", "agent:callbackAdvertise",
  "agent:callbackResolve", "agent:callbackRejectDuplicateResolve",
]);

export const expectedEmbeddedSwiftTests = new Set([
  ...expectedSmokeTests,
  ...expectedVectorTests,
  ...manifest.cases.flatMap(corpusCase =>
    corpusOperations.map(operation => `corpus:${corpusCase.id}:${operation}`)),
]);

/** Creates the strict validator for the complete embedded vector stream. */
export function createEmbeddedSwiftTestValidator() {
  const validator = createEmbeddedSwiftSmokeValidator(expectedEmbeddedSwiftTests);
  return {
    observe: validator.observe,
    result() {
      const result = validator.result();
      if (!result.passed) return result;
      if (result.metrics?.hotPathAllocations !== 0) {
        return {
          ...failureResult("completion", "hot-path allocation budget is not zero"),
          metrics: result.metrics,
        };
      }
      return result;
    },
  };
}
