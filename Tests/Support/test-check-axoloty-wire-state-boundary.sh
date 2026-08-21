#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-axoloty-wire-state-boundary.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

copy_tree() {
    rm -rf "$tmp/axoloty"
    mkdir -p "$tmp/axoloty/Packages/AxolotyWire/Sources/AxolotyWire"
    mkdir -p "$tmp/axoloty/Packages/AxolotyProtocol/Sources/AxolotyProtocol"
    cp "$root/Packages/AxolotyWire/Package.swift" "$tmp/axoloty/Packages/AxolotyWire/Package.swift"
    cp "$root/Packages/AxolotyProtocol/Sources/AxolotyProtocol/"*.swift \
       "$tmp/axoloty/Packages/AxolotyProtocol/Sources/AxolotyProtocol/"
    cp "$root/Packages/AxolotyWire/Sources/AxolotyWire/WireParserWorkspace.swift" \
       "$tmp/axoloty/Packages/AxolotyWire/Sources/AxolotyWire/"
}

expect_rejected() {
    label=$1
    mutation=$2
    copy_tree
    printf '%s\n' "$mutation" >> "$tmp/axoloty/Packages/AxolotyWire/Sources/AxolotyWire/WireParserWorkspace.swift"
    if (cd "$tmp/axoloty" && AXOLOTY_WIRE_PACKAGE_DIR="$tmp/axoloty/Packages/AxolotyWire" \
        AXOLOTY_PROTOCOL_PACKAGE_DIR="$tmp/axoloty/Packages/AxolotyProtocol" "$checker") >/dev/null 2>&1; then
        echo "error: checker accepted $label" >&2
        exit 1
    fi
}

expect_rejected "protocol import" "import AxolotyProtocol"
expect_rejected "subscriber capacity" "let maxSubscribers = 1"
expect_rejected "endpoint registry" "struct StaticIoEndpoints {}"

echo "AxolotyWire state-boundary negative tests passed"
