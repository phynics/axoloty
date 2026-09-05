#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
: "${AXOLOTY_WIFI_SSID:?AXOLOTY_WIFI_SSID is required}"
: "${AXOLOTY_WIFI_PASSWORD:?AXOLOTY_WIFI_PASSWORD is required}"
project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_dir=${EMBEDDED_BUILD_DIR:-/workspace/.build/embedded-swift-network}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
mkdir -p "$build_dir"
cd "$project_dir"
network_sdkconfig="$build_dir/sdkconfig"
if [ ! -f "$build_dir/CMakeCache.txt" ]; then
  idf.py -B "$build_dir" -D SDKCONFIG="$network_sdkconfig" set-target esp32c6
fi
node "$script_dir/generate-embedded-network-config.mjs" "$build_dir/esp-idf/main/axoloty_network_config.h"
trap 'rm -f "$build_dir/esp-idf/main/axoloty_network_config.h"' EXIT
idf.py -B "$build_dir" -D SDKCONFIG="$network_sdkconfig" build
EMBEDDED_SKIP_BUILD=1 EMBEDDED_BUILD_DIR="$build_dir" \
  EMBEDDED_VALIDATOR="$script_dir/embedded-network-validator.mjs" \
  EMBEDDED_VALIDATOR_FACTORY=createEmbeddedNetworkValidator \
  "$script_dir/embedded-swift-smoke.sh" "$@"
