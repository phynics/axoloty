#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-g4-runtime-package-boundary.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

write_fixture() {
    rm -rf "$tmp/Packages" "$tmp/Source"
    mkdir -p "$tmp/Source/Runtime" \
        "$tmp/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime"
    printf '%s\n' '// swift-tools-version:6.3' 'import PackageDescription' \
        'let package = Package(name: "AxolotyStaticRuntime", targets: [.target(name: "AxolotyStaticRuntime")])' \
        > "$tmp/Packages/AxolotyStaticRuntime/Package.swift"
    printf '%s\n' 'struct AxolotyRuntimeFixture {}' > "$tmp/Source/Runtime/AxolotyRuntimeFixture.swift"
    printf '%s\n' 'struct StaticFixture {}' > "$tmp/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime/Fixture.swift"
}

run_checker() {
    AXOLOTY_G4_HOST_RUNTIME_SOURCE_DIR="$tmp/Source/Runtime" \
    AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR="$tmp/Packages/AxolotyStaticRuntime" \
    AXOLOTY_G4_PRODUCTION_SOURCE_DIR="$tmp/Source" \
    AXOLOTY_G4_MANIFEST="$tmp/Package.swift" \
        "$checker"
}

cat > "$tmp/Package.swift" <<'EOF'
let package = Package(name: "fixture", targets: [
    .target(name: "Axoloty", path: "Source", sources: ["Runtime/AxolotyRuntimeFixture.swift"])
])
EOF

write_fixture
run_checker >/dev/null

cat > "$tmp/Package.swift" <<'EOF'
let package = Package(name: "fixture", targets: [
    .target(name: "Axoloty", path: "Source")
])
EOF
if run_checker >/dev/null 2>&1; then
    echo "error: package checker accepted legacy Source discovery" >&2
    exit 1
fi

write_fixture
printf '%s\n' 'struct Legacy: CommunicationManager {}' >> "$tmp/Source/Runtime/AxolotyRuntimeFixture.swift"
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
