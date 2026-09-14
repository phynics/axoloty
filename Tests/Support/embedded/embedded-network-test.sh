#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
: "${AXOLOTY_WIFI_SSID:?AXOLOTY_WIFI_SSID is required}"
: "${AXOLOTY_WIFI_PASSWORD:?AXOLOTY_WIFI_PASSWORD is required}"
project_dir=${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}
build_dir=${EMBEDDED_BUILD_DIR:-/workspace/.build/embedded-swift-network}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AXOLOTY_EMBEDDED_CORE_TOOLS_NO_EXEC=1 . "$script_dir/prepare-embedded-core-tools.sh"
embedded_core_prepare_tools "$build_dir" "$script_dir/resolve-embedded-core.sh"
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
. "$script_dir/embedded-build-cache.sh"
mkdir -p "$build_dir"
cd "$project_dir"
network_sdkconfig="$build_dir/sdkconfig"
config_flags="network"
axoloty_enable_esp_idf_ccache "$project_dir" esp32c6 "$config_flags"
axoloty_prepare_esp_idf_build "$build_dir" esp32c6 0 "$config_flags" -D SDKCONFIG="$network_sdkconfig"
node "$script_dir/generate-embedded-network-config.mjs" "$build_dir/esp-idf/main/axoloty_network_config.h"
trap 'rm -f "$build_dir/esp-idf/main/axoloty_network_config.h"' EXIT
idf.py -B "$build_dir" -D SDKCONFIG="$network_sdkconfig" build
EMBEDDED_SKIP_BUILD=1 EMBEDDED_BUILD_DIR="$build_dir" \
  EMBEDDED_VALIDATOR="$script_dir/embedded-network-validator.mjs" \
  EMBEDDED_VALIDATOR_FACTORY=createEmbeddedNetworkValidator \
  "$script_dir/embedded-swift-smoke.sh" "$@"
