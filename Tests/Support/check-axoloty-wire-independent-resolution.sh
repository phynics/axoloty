#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Resolves the downstream AxolotyWire fixture and asserts no host runtime
# dependencies are fetched. Must run inside the devcontainer (needs `swift`).

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fixture="$root/Packages/AxolotyWire/Fixtures/DownstreamConsumer"

cd "$fixture"
swift package resolve
swift build
deps=$(swift package show-dependencies --format flatlist)

for forbidden in mqtt-nio swift-nio swift-nio-ssl swift-nio-transport-services swift-log ErrorKit swift-json IkigaJSON swift-docc-plugin; do
    if echo "$deps" | grep -qi "$forbidden"; then
        echo "error: AxolotyWire downstream fixture resolved forbidden host dependency: $forbidden" >&2
        exit 1
    fi
done

echo "AxolotyWire resolves independently without host runtime dependencies"
