#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Negative self-test for the #638 dependency boundary. The maintained checker
# must reject a protocol source that imports a host-only module.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp -R "$root/Packages/AxolotyProtocol" "$tmp/package"
printf '\nimport Foundation\n' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"

if AXOLOTY_PROTOCOL_PACKAGE_DIR="$tmp/package" \
    "$root/Tests/Support/check-axoloty-protocol-package.sh" >/dev/null 2>&1; then
    echo "error: protocol dependency checker accepted a Foundation import" >&2
    exit 1
fi

rm -rf "$tmp/package"
cp -R "$root/Packages/AxolotyProtocol" "$tmp/package"
printf '%s' 'import NIOHTTP1' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
printf '\n' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
printf '%s' 'import Logging' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
printf '\n' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
printf '%s' 'actor ForbiddenActor {}' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
printf '\n' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
printf '%s' 'struct ForbiddenController {}' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
printf '\n' >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
if AXOLOTY_PROTOCOL_PACKAGE_DIR="$tmp/package" "$root/Tests/Support/check-axoloty-protocol-package.sh" >/dev/null 2>&1; then
    echo "error: checker accepted forbidden NIO/logging/actor/controller boundaries" >&2
    exit 1
fi

rm -rf "$tmp/package"
cp -R "$root/Packages/AxolotyProtocol" "$tmp/package"
sed -i 's/\.product(name: "AxolotyWire", package: "AxolotyWire")/.product(name: "NIO", package: "swift-nio")/' "$tmp/package/Package.swift"
if AXOLOTY_PROTOCOL_PACKAGE_DIR="$tmp/package" "$root/Tests/Support/check-axoloty-protocol-package.sh" >/dev/null 2>&1; then
    echo "error: checker accepted forbidden manifest dependency" >&2
    exit 1
fi

echo "AxolotyProtocol forbidden-boundary negative tests passed"
