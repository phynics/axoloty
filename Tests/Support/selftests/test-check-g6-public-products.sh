#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-g6-public-products.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repository"
mkdir -p "$fixture/Tests/Support/checks" "$fixture/Tests/Support/evidence"
cp "$checker" "$fixture/Tests/Support/checks/check-g6-public-products.sh"
cp "$root/Tests/Support/evidence/validate-g6-products.mjs" "$fixture/Tests/Support/evidence/validate-g6-products.mjs"
cat >"$fixture/Package.swift" <<'EOF'
let package = Package(
  products: [
    .library(name: "Axoloty"), .library(name: "AxolotyWire"),
    .library(name: "AxolotyProtocol"), .library(name: "AxolotyObjectModel"),
    .library(name: "AxolotyCoatyModels"), .library(name: "AxolotyIoRouting"),
    .library(name: "AxolotySensorThings"), .library(name: "AxolotyStaticRuntime"),
    .executable(name: "axoloty-tool"), .executable(name: "ax"),
    .executable(name: "axoloty-inspect"), .executable(name: "axoloty-mcp")
  ]
)
EOF
(cd "$fixture" && Tests/Support/checks/check-g6-public-products.sh) >/dev/null
sed -i 's/\.executable(name: "axoloty-mcp")/.executable(name: "unexpected")/' "$fixture/Package.swift"
if (cd "$fixture" && Tests/Support/checks/check-g6-public-products.sh) >/dev/null 2>&1; then
    echo "error: product inventory accepted an unexpected product" >&2
    exit 1
fi

echo "G6 public product inventory negative self-test passed"
