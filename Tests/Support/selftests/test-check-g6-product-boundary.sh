#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-g6-product-boundary.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repository"
mkdir -p "$fixture/Source/Runtime" "$fixture/Packages/AxolotyStaticRuntime/Sources" "$fixture/Tests/Support/checks"
cp "$checker" "$fixture/Tests/Support/checks/check-g6-product-boundary.sh"
printf '%s\n' \
    'let package = Package(' \
    '    targets: [' \
    '        .target(' \
    '            name: "Axoloty",' \
    '            dependencies: ["AxolotyProtocol", "AxolotyWire"]' \
    '        ),' \
    '    ]' \
    ')' > "$fixture/Package.swift"
printf '%s\n' 'struct CurrentProduct {}' > "$fixture/Source/Runtime/Current.swift"
printf '%s\n' 'struct StaticProduct {}' > "$fixture/Packages/AxolotyStaticRuntime/Sources/Static.swift"
(cd "$fixture" && Tests/Support/checks/check-g6-product-boundary.sh) >/dev/null

printf '%s\n' 'import MQTTNIOClient' > "$fixture/Source/Runtime/Current.swift"
if (cd "$fixture" && Tests/Support/checks/check-g6-product-boundary.sh) >/dev/null 2>&1; then
    echo "error: product boundary accepted a legacy transport symbol" >&2
    exit 1
fi

echo "G6 product boundary negative self-test passed"
