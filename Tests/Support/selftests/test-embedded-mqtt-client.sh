#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
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
grep -Fq 'network:mqttConnect' Tests/Support/embedded/embedded-network-validator.mjs
grep -Fq 'network:rejectOversize' Tests/Support/embedded/embedded-network-validator.mjs
grep -Fq 'network:rejectOutOfOrder' Tests/Support/embedded/embedded-network-validator.mjs
grep -Fq 'network:lastWillConfigured' Tests/Support/embedded/embedded-network-validator.mjs
grep -Fq 'network:reconnect' Tests/Support/embedded/embedded-network-validator.mjs
grep -Fq 'let cleanedUp = axoloty_network_cleanup() != 0' "$main"
grep -Fq 'network_wait_ticks(start, overall_deadline_ms, 30000)' Embedded/swift/main/network_bootstrap.c
grep -Fq 'esp_mqtt_client_destroy(mqtt_client)' Embedded/swift/main/network_bootstrap.c
grep -Fq 'The static endpoint profile has no reassembly buffer.' Embedded/swift/main/network_bootstrap.c
grep -Fq 'event->current_data_offset == 0 && event->data_len == event->total_data_len' Embedded/swift/main/network_bootstrap.c
shared_flags=Embedded/swift/main/embedded_shared_flags.h
test -f "$shared_flags"
grep -Fq 'AxolotyAtomicUInt mqtt_bits' "$shared_flags"
grep -Fq 'AxolotyAtomicUInt agent_connect_count' "$shared_flags"
grep -Fq 'AxolotyAtomicUInt network_connect_count' "$shared_flags"
grep -Fq 'AxolotyAtomicUInt wifi_retry_count' "$shared_flags"
grep -Fq 'AxolotyAtomicInt forced_wifi_disconnect' "$shared_flags"
grep -Fq '__ATOMIC_ACQUIRE' "$shared_flags"
grep -Fq '__ATOMIC_RELEASE' "$shared_flags"
grep -Fq '__ATOMIC_ACQ_REL' "$shared_flags"
! grep -Eq 'volatile (unsigned|int).*network_(mqtt_bits|connect_count|forced_wifi_disconnect)' Embedded/swift/main/network_bootstrap.c
! grep -Fq 'volatile unsigned int agent_connect_count' Embedded/swift/main/network_bootstrap.c
! grep -Fq 'volatile unsigned int wifi_retry_count' Embedded/swift/main/network_bootstrap.c
shared_flags_test="$tmp/embedded-shared-flags-test"
compiler=${CC:-clang}
command -v "$compiler" >/dev/null
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pthread \
  Tests/Support/embedded/embedded-shared-flags-test.c -o "$shared_flags_test"
"$shared_flags_test"
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
