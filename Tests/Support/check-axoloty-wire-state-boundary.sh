#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforces the #639 ownership split: AxolotyWire retains the legacy
# wire-facing router/endpoint compatibility layer and syntax/workspace code;
# the portable protocol package owns the new bounded correlation state. The
# router rewrite remains explicitly deferred to #640.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
wire="${AXOLOTY_WIRE_PACKAGE_DIR:-$root/Packages/AxolotyWire}"
protocol="${AXOLOTY_PROTOCOL_PACKAGE_DIR:-$root/Packages/AxolotyProtocol}"

test -f "$wire/Package.swift"
test -f "$protocol/Sources/AxolotyProtocol/ProtocolBufferConfig.swift"
test -f "$protocol/Sources/AxolotyProtocol/ProtocolPendingRequest.swift"

if grep -Eq 'import[[:space:]]+AxolotyProtocol|ProtocolPendingRequest|ProtocolBufferConfig' \
    "$wire/Package.swift" "$wire"/Sources/AxolotyWire/*.swift; then
    echo "error: AxolotyWire imports or defines G2 protocol state" >&2
    exit 1
fi

test -f "$protocol/Sources/AxolotyProtocol/ProtocolBufferConfig.swift"
test -f "$protocol/Sources/AxolotyProtocol/ProtocolPendingRequest.swift"

grep -Fq 'WireParserWorkspace' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"
grep -Fq 'InlineWireParserWorkspace<520>' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"
grep -Fq 'HostWireParserWorkspace' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"

echo "AxolotyWire/AxolotyProtocol state boundary passed"
