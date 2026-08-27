#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-g6-architecture.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repository"
mkdir -p "$fixture/Packages/AxolotyWire/Sources/AxolotyWire" \
    "$fixture/Packages/AxolotyProtocol/Sources/AxolotyProtocol" \
    "$fixture/Embedded/swift/components/axoloty_wire" \
    "$fixture/Embedded/swift/components/axoloty_protocol" \
    "$fixture/Tests/Support"
cp "$checker" "$fixture/Tests/Support/check-g6-architecture.sh"
cp "$root/Tests/Support/validate-g6-source-receipts.mjs" "$fixture/Tests/Support/validate-g6-source-receipts.mjs"
printf '%s\n' 'struct WireFixture {}' > "$fixture/Packages/AxolotyWire/Sources/AxolotyWire/Wire.swift"
printf '%s\n' 'struct ProtocolFixture {}' > "$fixture/Packages/AxolotyProtocol/Sources/AxolotyProtocol/Protocol.swift"
printf '%s\n' 'let package = Package(name: "AxolotyWire", targets: [.target(name: "AxolotyWire", path: "Sources/AxolotyWire")])' > "$fixture/Packages/AxolotyWire/Package.swift"
printf '%s\n' 'let package = Package(name: "AxolotyProtocol", targets: [.target(name: "AxolotyProtocol", path: "Sources/AxolotyProtocol")])' > "$fixture/Packages/AxolotyProtocol/Package.swift"
printf '%s\n' 'path: "Packages/AxolotyWire/Sources/AxolotyWire"' 'path: "Packages/AxolotyProtocol/Sources/AxolotyProtocol"' > "$fixture/Package.swift"
printf '%s\n' 'file(GLOB AXOLOTY_WIRE_SOURCES "${AXOLOTY_ROOT}/Packages/AxolotyWire/Sources/AxolotyWire/*.swift")' > "$fixture/Embedded/swift/components/axoloty_wire/CMakeLists.txt"
printf '%s\n' 'file(GLOB AXOLOTY_PROTOCOL_SOURCES "${AXOLOTY_ROOT}/Packages/AxolotyProtocol/Sources/AxolotyProtocol/*.swift")' > "$fixture/Embedded/swift/components/axoloty_protocol/CMakeLists.txt"

(cd "$fixture" && "$fixture/Tests/Support/check-g6-architecture.sh") >/dev/null

wire_hash=$(sha256sum "$fixture/Packages/AxolotyWire/Sources/AxolotyWire/Wire.swift" | awk '{print $1}')
protocol_hash=$(sha256sum "$fixture/Packages/AxolotyProtocol/Sources/AxolotyProtocol/Protocol.swift" | awk '{print $1}')
for receipt in host embedded; do
    printf '{"schemaVersion":1,"modules":[{"module":"AxolotyWire","sources":[{"path":"Packages/AxolotyWire/Sources/AxolotyWire/Wire.swift","sha256":"%s"}]},{"module":"AxolotyProtocol","sources":[{"path":"Packages/AxolotyProtocol/Sources/AxolotyProtocol/Protocol.swift","sha256":"%s"}]}]}\n' \
        "$wire_hash" "$protocol_hash" > "$tmp/$receipt.json"
done
(cd "$fixture" && AXOLOTY_G6_REQUIRE_SOURCE_RECEIPTS=1 \
    AXOLOTY_G6_HOST_RECEIPT="$tmp/host.json" \
    AXOLOTY_G6_EMBEDDED_RECEIPT="$tmp/embedded.json" \
    "$fixture/Tests/Support/check-g6-architecture.sh") >/dev/null
sed -i 's/"sha256":"[0-9a-f]*/"sha256":"0000000000000000000000000000000000000000000000000000000000000000/' "$tmp/embedded.json"
if (cd "$fixture" && AXOLOTY_G6_REQUIRE_SOURCE_RECEIPTS=1 \
    AXOLOTY_G6_HOST_RECEIPT="$tmp/host.json" \
    AXOLOTY_G6_EMBEDDED_RECEIPT="$tmp/embedded.json" \
    "$fixture/Tests/Support/check-g6-architecture.sh") >/dev/null 2>&1; then
    echo "error: checker accepted a mismatched compiler-input receipt" >&2
    exit 1
fi
sed -i 's#Packages/AxolotyProtocol/Sources/AxolotyProtocol/\*\.swift#Packages/AxolotyProtocol/Sources/Missing/*.swift#' \
    "$fixture/Embedded/swift/components/axoloty_protocol/CMakeLists.txt"
if (cd "$fixture" && "$fixture/Tests/Support/check-g6-architecture.sh") >/dev/null 2>&1; then
    echo "error: checker accepted a missing protocol source inclusion" >&2
    exit 1
fi

echo "G6 architecture checker negative self-test passed"
