#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
AXOLOTY_WIFI_SSID='ssid ü;${x}' AXOLOTY_WIFI_PASSWORD='p@ss;"$x' \
  AXOLOTY_MQTT_HOST='broker.local' AXOLOTY_MQTT_PORT=1884 \
  node Tests/Support/generate-embedded-network-config.mjs "$tmp/config.h"
test "$(grep -c 'AXOLOTY_NETWORK_CONFIGURED 1' "$tmp/config.h")" -eq 1
! grep -F 'ssid ü' "$tmp/config.h"
! grep -F 'p@ss' "$tmp/config.h"
! grep -F 'axoloty_mqtt_password' "$tmp/config.h"
node --input-type=module <<'JS'
import { createEmbeddedNetworkValidator, expectedNetworkTests } from "./Tests/Support/embedded-network-validator.mjs";
if (expectedNetworkTests.size < 7) process.exit(1);
const validator = createEmbeddedNetworkValidator();
if (!validator || typeof validator.observe !== "function") process.exit(1);
JS
echo "embedded network support self-tests passed"
