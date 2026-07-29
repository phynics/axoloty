#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

overlay=Embedded/swift/main/EmbeddedMQTTClient.swift
main=Embedded/swift/main/Main.swift
header=Embedded/swift/main/BridgingHeader.h
test -f "$overlay"
grep -Fq 'struct EmbeddedMQTTClient' "$overlay"
grep -Fq 'axoloty_mqtt_connect_wait' "$overlay"
grep -Fq 'axoloty_mqtt_subscribe_wait(topic, topicLength, deadlineMS)' "$overlay"
grep -Fq 'axoloty_mqtt_publish' "$overlay"
grep -Fq 'axoloty_mqtt_wait_loopback' "$overlay"
grep -Fq 'axoloty_mqtt_disconnect' "$overlay"
grep -Fq 'axoloty_mqtt_configure_last_will' "$overlay"
grep -Fq 'axoloty_mqtt_reconnect_wait' "$overlay"
grep -Fq 'EmbeddedMQTTClient' "$main"
grep -Fq 'axoloty_mqtt_connect_wait' "$header"
grep -Fq 'network:mqttConnect' Tests/Support/embedded-network-validator.mjs
grep -Fq 'network:rejectOversize' Tests/Support/embedded-network-validator.mjs
grep -Fq 'network:rejectOutOfOrder' Tests/Support/embedded-network-validator.mjs
grep -Fq 'network:lastWillConfigured' Tests/Support/embedded-network-validator.mjs
grep -Fq 'network:reconnect' Tests/Support/embedded-network-validator.mjs
grep -Fq 'let cleanedUp = axoloty_network_cleanup() != 0' "$main"
grep -Fq 'network_wait_ticks(start, overall_deadline_ms, 30000)' Embedded/swift/main/network_bootstrap.c
grep -Fq 'esp_mqtt_client_destroy(mqtt_client)' Embedded/swift/main/network_bootstrap.c
grep -Fq 'agent_fragment_active' Embedded/swift/main/network_bootstrap.c
grep -Fq 'network_reset_agent_fragment()' Embedded/swift/main/network_bootstrap.c
node --input-type=module <<'JS'
import fs from "node:fs";
const source = fs.readFileSync("Embedded/swift/main/Main.swift", "utf8");
const calls = [
  "client.configureLastWill(", "client.connect(", "client.subscribe(",
  "client.waitForReconnect(", "client.publish(",
  "client.waitForLoopback(", "client.disconnect(",
];
let prior = -1;
for (const call of calls) {
  const position = source.indexOf(call, prior + 1);
  if (position < 0 || position <= prior) process.exit(1);
  prior = position;
}
JS
echo "embedded MQTT overlay support self-test passed"
