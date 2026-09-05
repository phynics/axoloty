#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforces the #639/#640 ownership split: AxolotyWire owns syntax and parser
# workspaces only; AxolotyProtocol owns all processor, subscription,
# association, handler, and correlation state.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
wire="${AXOLOTY_WIRE_PACKAGE_DIR:-$root/Packages/AxolotyWire}"
protocol="${AXOLOTY_PROTOCOL_PACKAGE_DIR:-$root/Packages/AxolotyProtocol}"

test -f "$wire/Package.swift"
for required in \
    ProtocolBufferConfig.swift ProtocolProcessor.swift \
    ProtocolActionSink.swift ProtocolHandlerTable.swift ProtocolCapacityError.swift \
    ProtocolRouteClassifier.swift ProtocolSubscriptionRegistry.swift; do
    test -f "$protocol/Sources/AxolotyProtocol/$required"
done

# Keep the shared processor Interface and handler seam visible in the boundary check.
grep -Fq 'processInbound' "$protocol/Sources/AxolotyProtocol/ProtocolProcessor.swift"
grep -Fq 'processOutbound' "$protocol/Sources/AxolotyProtocol/ProtocolProcessor.swift"
grep -Fq 'expire(nowMS:' "$protocol/Sources/AxolotyProtocol/ProtocolProcessor.swift"
grep -Fq '@convention(thin)' "$protocol/Sources/AxolotyProtocol/ProtocolHandlerTable.swift"

if grep -Eq 'import[[:space:]]+AxolotyProtocol|ProtocolPendingRequest|ProtocolBufferConfig|ProtocolProcessor|ProtocolActionSink|ProtocolHandlerEntry|ProtocolRouteClassifier|EmbeddedMessageRouter|StaticDispatchTable|StaticFamilyTable|StaticIoEndpoints|MessageRouter|WireCapacityError' \
    "$wire/Package.swift" "$wire"/Sources/AxolotyWire/*.swift; then
    echo "error: AxolotyWire imports or defines G2 protocol state" >&2
    exit 1
fi

if find "$wire/Sources/AxolotyWire" -maxdepth 1 -type f \( \
    -name '*Router.swift' -o -name 'Static*swift' -o -name '*CapacityError.swift' \) | grep -q .; then
    echo "error: protocol-state source remains under AxolotyWire" >&2
    exit 1
fi

grep -Fq 'WireParserWorkspace' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"
grep -Fq 'InlineWireParserWorkspace<2056>' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"
grep -Fq 'HostWireParserWorkspace' "$wire/Sources/AxolotyWire/WireParserWorkspace.swift"

echo "AxolotyWire/AxolotyProtocol state boundary passed"
