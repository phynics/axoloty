#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-g6-architecture.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repository"
mkdir -p "$fixture/Packages/AxolotyWire/Sources/AxolotyWire" \
    "$fixture/Packages/AxolotyProtocol/Sources/AxolotyProtocol" \
    "$fixture/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel" \
    "$fixture/Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels" \
    "$fixture/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime" \
    "$fixture/docs" \
    "$fixture/Tests/Support/checks" \
    "$fixture/Tests/Support/evidence"
cp "$checker" "$fixture/Tests/Support/checks/check-g6-architecture.sh"
cp "$root/Tests/Support/evidence/validate-g6-source-receipts.mjs" "$fixture/Tests/Support/evidence/validate-g6-source-receipts.mjs"
cp "$root/Tests/Support/evidence/emit-g6-source-receipt.mjs" "$fixture/Tests/Support/evidence/emit-g6-source-receipt.mjs"
printf '%s\n' 'struct WireFixture {}' > "$fixture/Packages/AxolotyWire/Sources/AxolotyWire/Wire.swift"
printf '%s\n' 'struct ProtocolFixture {}' > "$fixture/Packages/AxolotyProtocol/Sources/AxolotyProtocol/Protocol.swift"
printf '%s\n' 'struct ObjectModelFixture {}' > "$fixture/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/Object.swift"
printf '%s\n' 'struct CoatyModelsFixture {}' > "$fixture/Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels/Coaty.swift"
printf '%s\n' 'struct StaticRuntimeFixture {}' > "$fixture/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime/Runtime.swift"
printf '%s\n' 'let package = Package(name: "AxolotyWire", targets: [.target(name: "AxolotyWire", path: "Sources/AxolotyWire")])' > "$fixture/Packages/AxolotyWire/Package.swift"
printf '%s\n' 'let package = Package(name: "AxolotyProtocol", targets: [.target(name: "AxolotyProtocol", path: "Sources/AxolotyProtocol")])' > "$fixture/Packages/AxolotyProtocol/Package.swift"
printf '%s\n' \
    'path: "Packages/AxolotyWire/Sources/AxolotyWire"' \
    'path: "Packages/AxolotyProtocol/Sources/AxolotyProtocol"' \
    > "$fixture/Package.swift"
cat > "$fixture/docs/contract.json" <<'JSON'
{"swift":{"requiredCompilerFlags":["-swift-version","6","-enable-experimental-feature","Embedded","-enable-experimental-feature","Lifetimes"]},"staticRuntimeMacro":{"executable":"AxolotyStaticRuntimeMacrosImplementation-tool","pluginModule":"AxolotyStaticRuntimeMacrosImplementation"},"portablePackages":[
  {"package":"AxolotyWire","sourcePath":"Packages/AxolotyWire/Sources/AxolotyWire"},
  {"package":"AxolotyObjectModel","sourcePath":"Packages/AxolotyObjectModel/Sources/AxolotyObjectModel"},
  {"package":"AxolotyProtocol","sourcePath":"Packages/AxolotyProtocol/Sources/AxolotyProtocol"},
  {"package":"AxolotyCoatyModels","sourcePath":"Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels"},
  {"package":"AxolotyStaticRuntime","sourcePath":"Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime"}
]}
JSON

(cd "$fixture" && AXOLOTY_G6_CONSUMER_REPORT="$fixture/docs/contract.json" "$fixture/Tests/Support/checks/check-g6-architecture.sh") >/dev/null

cat > "$tmp/compile_commands.json" <<'EOF'
[{"file":"Packages/AxolotyWire/Sources/AxolotyWire/Wire.swift","arguments":["swiftc","Wire.swift"]},{"file":"Packages/AxolotyProtocol/Sources/AxolotyProtocol/Protocol.swift","arguments":["swiftc","Protocol.swift"]}]
EOF
for receipt in host embedded; do
    build_system=$(test "$receipt" = host && printf swiftpm || printf esp-idf-cmake)
    node "$root/Tests/Support/evidence/emit-g6-source-receipt.mjs" \
        "$fixture" "$build_system" "x86_64-unknown-linux-gnu" "Swift 6.3" \
        "$tmp/compile_commands.json" "$tmp/$receipt.json"
done
(cd "$fixture" && AXOLOTY_G6_REQUIRE_SOURCE_RECEIPTS=1 \
    AXOLOTY_G6_HOST_RECEIPT="$tmp/host.json" \
    AXOLOTY_G6_EMBEDDED_RECEIPT="$tmp/embedded.json" \
    AXOLOTY_G6_CONSUMER_REPORT="$fixture/docs/contract.json" \
    "$fixture/Tests/Support/checks/check-g6-architecture.sh") >/dev/null
sed -i 's/"sha256":"[0-9a-f]*/"sha256":"0000000000000000000000000000000000000000000000000000000000000000/' "$tmp/embedded.json"
if (cd "$fixture" && AXOLOTY_G6_REQUIRE_SOURCE_RECEIPTS=1 \
    AXOLOTY_G6_HOST_RECEIPT="$tmp/host.json" \
    AXOLOTY_G6_EMBEDDED_RECEIPT="$tmp/embedded.json" \
    AXOLOTY_G6_CONSUMER_REPORT="$fixture/docs/contract.json" \
    "$fixture/Tests/Support/checks/check-g6-architecture.sh") >/dev/null 2>&1; then
    echo "error: checker accepted a mismatched compiler-input receipt" >&2
    exit 1
fi
rm -f "$fixture/Packages/AxolotyProtocol/Sources/AxolotyProtocol/Protocol.swift"
if (cd "$fixture" && AXOLOTY_G6_CONSUMER_REPORT="$fixture/docs/contract.json" \
    "$fixture/Tests/Support/checks/check-g6-architecture.sh") >/dev/null 2>&1; then
    echo "error: checker accepted a missing protocol source root" >&2
    exit 1
fi

echo "G6 architecture checker negative self-test passed"
