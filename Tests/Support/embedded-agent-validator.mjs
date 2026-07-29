// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { createEmbeddedSwiftSmokeValidator } from "./embedded-swift-smoke-validator.mjs";
export const expectedAgentTests = new Set([
  "exchange:wifi", "exchange:ip", "exchange:mqttConnect", "exchange:subscribe",
  "exchange:reconnect",
  "exchange:advertise", "exchange:discover", "exchange:resolve",
  "exchange:deadvertise", "exchange:disconnect",
]);
export const expectedLastWillTests = new Set([
  "exchange:wifi", "exchange:ip", "exchange:mqttConnect", "exchange:subscribe",
  "exchange:reconnect", "exchange:advertise", "exchange:deadvertise", "exchange:disconnect",
]);
export const expectedBrokerRestartTests = new Set([
  "exchange:wifi", "exchange:ip", "exchange:mqttConnect", "exchange:subscribe",
  "exchange:reconnect", "exchange:brokerReconnect", "exchange:advertise",
  "exchange:discover", "exchange:resolve", "exchange:deadvertise", "exchange:disconnect",
]);

/** Creates the strict validator for one participant in the two-device exchange. */
export function createEmbeddedAgentValidator(expectedTests = expectedAgentTests) {
  return createEmbeddedSwiftSmokeValidator(expectedTests);
}
