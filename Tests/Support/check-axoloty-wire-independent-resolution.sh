#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Resolves the downstream AxolotyWire fixture and asserts no host runtime
# dependencies are fetched. swift-json is intentional: its disabled
# FoundationSupport trait exposes only IkigaJSONCore. Its swift-nio package
# is resolution-only and must not be built or linked by this fixture.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fixture="$root/Packages/AxolotyWire/Fixtures/DownstreamConsumer"

cd "$fixture"
swift package resolve
build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT
swift build >"$build_log" 2>&1
deps=$(swift package show-dependencies --format flatlist)

if ! echo "$deps" | grep -qi "swift-nio"; then
    echo "error: swift-nio was not present as the intentional resolution-only transitive" >&2
    exit 1
fi
if grep -Eq 'Compiling (NIO|NIOCore|NIOFoundationCompat|NIOPosix) ' "$build_log"; then
    echo "error: a swift-nio target was built for the standalone AxolotyWire fixture" >&2
    exit 1
fi

for forbidden in mqtt-nio swift-nio-ssl swift-nio-transport-services swift-log ErrorKit IkigaJSON swift-docc-plugin; do
    if echo "$deps" | grep -qi "$forbidden"; then
        echo "error: AxolotyWire downstream fixture resolved forbidden host dependency: $forbidden" >&2
        exit 1
    fi
done

echo "AxolotyWire resolves independently without host runtime dependencies"
