#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-g4-runtime-package-boundary.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

write_fixture() {
    rm -rf "$tmp/Packages"
    mkdir -p "$tmp/Packages/AxolotyRuntime/Sources/AxolotyRuntime" \
        "$tmp/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime"
    printf '%s\n' '// swift-tools-version:6.3' 'import PackageDescription' \
        'let package = Package(name: "AxolotyRuntime", targets: [.target(name: "AxolotyRuntime")])' \
        > "$tmp/Packages/AxolotyRuntime/Package.swift"
    printf '%s\n' '// swift-tools-version:6.3' 'import PackageDescription' \
        'let package = Package(name: "AxolotyStaticRuntime", targets: [.target(name: "AxolotyStaticRuntime")])' \
        > "$tmp/Packages/AxolotyStaticRuntime/Package.swift"
    printf '%s\n' 'struct RuntimeFixture {}' > "$tmp/Packages/AxolotyRuntime/Sources/AxolotyRuntime/Fixture.swift"
    printf '%s\n' 'struct StaticFixture {}' > "$tmp/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime/Fixture.swift"
}

run_checker() {
    AXOLOTY_G4_RUNTIME_PACKAGE_DIR="$tmp/Packages/AxolotyRuntime" \
    AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR="$tmp/Packages/AxolotyStaticRuntime" \
        "$checker"
}

write_fixture
run_checker >/dev/null

write_fixture
printf '%s\n' 'struct Legacy: CommunicationManager {}' >> "$tmp/Packages/AxolotyRuntime/Sources/AxolotyRuntime/Fixture.swift"
if run_checker >/dev/null 2>&1; then
    echo "error: package checker accepted a legacy lifecycle symbol" >&2
    exit 1
fi

write_fixture
rm -rf "$tmp/Packages/AxolotyStaticRuntime"
if run_checker >/dev/null 2>&1; then
    echo "error: package checker accepted a missing static runtime root" >&2
    exit 1
fi

echo "G4 runtime package boundary negative tests passed"
