#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforces the #639 ownership split: AxolotyWire is syntax and workspace only;
# bounded protocol state, routers, and endpoint registries live in
# AxolotyProtocol.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
wire="${AXOLOTY_WIRE_PACKAGE_DIR:-$root/Packages/AxolotyWire}"
protocol="${AXOLOTY_PROTOCOL_PACKAGE_DIR:-$root/Packages/AxolotyProtocol}"

test -f "$wire/Package.swift"
test -f "$protocol/Sources/AxolotyProtocol/ProtocolBufferConfig.swift"
test -f "$protocol/Sources/AxolotyProtocol/ProtocolPendingRequest.swift"

if grep -Eq 'AxolotyProtocol|EmbeddedMessageRouter|StaticDispatchTable|StaticFamilyTable|StaticIoEndpoints|WireCapacityError|ProtocolCapacityError|ProtocolBufferConfig|maxSubscribers|maxFamilyEntries|maxFamilySubscribers' \
    "$wire/Package.swift" "$wire"/Sources/AxolotyWire/*.swift; then
    echo "error: AxolotyWire contains protocol-state ownership" >&2
    exit 1
fi

for name in EmbeddedMessageRouter MessageRouter StaticDispatchTable StaticFamilyTable StaticIoEndpoints ProtocolCapacityError; do
    test -f "$protocol/Sources/AxolotyProtocol/$name.swift"
done

grep -Fq 'WireParserWorkspace' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"
grep -Fq 'InlineWireParserWorkspace<520>' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"
grep -Fq 'HostWireParserWorkspace' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"

echo "AxolotyWire/AxolotyProtocol state boundary passed"
