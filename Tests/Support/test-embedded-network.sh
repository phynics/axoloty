#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
AXOLOTY_WIFI_SSID='ssid ü;${x}' AXOLOTY_WIFI_PASSWORD='p@ss;"$x' \
  AXOLOTY_MQTT_HOST='broker.local' AXOLOTY_MQTT_PORT=1884 \
  AXOLOTY_DEVICE_ROLE=A AXOLOTY_AGENT_SCENARIO=last-will \
  AXOLOTY_RUNTIME_IDENTITY='site-a-device-01' \
  node Tests/Support/generate-embedded-network-config.mjs "$tmp/config.h"
test "$(grep -c 'AXOLOTY_NETWORK_CONFIGURED 1' "$tmp/config.h")" -eq 1
! grep -F 'ssid ü' "$tmp/config.h"
! grep -F 'p@ss' "$tmp/config.h"
! grep -F 'axoloty_mqtt_password' "$tmp/config.h"
grep -Fq 'axoloty_device_role = 1U' "$tmp/config.h"
grep -Fq 'axoloty_agent_scenario = 1U' "$tmp/config.h"
grep -Fq 'axoloty_runtime_identity[] = { 115, 105, 116, 101, 45, 97, 45, 100, 101, 118, 105, 99, 101, 45, 48, 49, 0 }' "$tmp/config.h"
grep -Fq 'esp_read_mac' Embedded/swift/main/network_bootstrap.c
grep -Fq 'axoloty_runtime_identity_prepare' Embedded/swift/main/network_bootstrap.c
grep -Fq '"runtime_identity.c"' Embedded/swift/main/CMakeLists.txt
awk '
  /^int axoloty_mqtt_connect_wait\(/ { capture = 1 }
  capture {
    if ($0 ~ /if \(!network_prepare_client_id\(\)\) return 0;/) prepared = 1
    if ($0 ~ /config\.credentials\.client_id = network_client_id;/) assigned = 1
    if ($0 ~ /esp_mqtt_client_init\(/) {
      if (!prepared || !assigned) exit 1
      exit 0
    }
  }
  END { if (!prepared || !assigned) exit 1 }
' Embedded/swift/main/network_bootstrap.c
awk '
  /^unsigned int axoloty_agent_test\(/ { capture = 1 }
  capture {
    if ($0 ~ /if \(!network_prepare_client_id\(\)\) goto agent_done;/) prepared = 1
    if ($0 ~ /config\.credentials\.client_id = network_client_id;/) {
      if (!prepared) exit 1
      assigned = 1
    }
    if ($0 ~ /esp_mqtt_client_init\(/) {
      if (!prepared || !assigned) exit 1
      exit 0
    }
  }
  END { if (!prepared || !assigned) exit 1 }
' Embedded/swift/main/network_bootstrap.c
if AXOLOTY_WIFI_SSID=ssid AXOLOTY_WIFI_PASSWORD=password \
  AXOLOTY_RUNTIME_IDENTITY='bad/name' \
  node Tests/Support/generate-embedded-network-config.mjs "$tmp/invalid.h" 2>/dev/null; then
  echo "invalid runtime identity unexpectedly accepted" >&2
  exit 1
fi
node --input-type=module <<'JS'
import { createEmbeddedNetworkValidator, expectedNetworkTests } from "./Tests/Support/embedded-network-validator.mjs";
import { createEmbeddedAgentValidator, expectedAgentTests, expectedLastWillTests, expectedBrokerRestartTests } from "./Tests/Support/embedded-agent-validator.mjs";
if (expectedNetworkTests.size < 7) process.exit(1);
const validator = createEmbeddedNetworkValidator();
if (!validator || typeof validator.observe !== "function") process.exit(1);
if (expectedAgentTests.size !== 10) process.exit(1);
if (expectedLastWillTests.size !== 8) process.exit(1);
if (expectedBrokerRestartTests.size !== 11) process.exit(1);
if (typeof createEmbeddedAgentValidator().observe !== "function") process.exit(1);
JS
echo "embedded network support self-tests passed"
