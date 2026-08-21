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

echo "AxolotyProtocol forbidden-import negative test passed"
