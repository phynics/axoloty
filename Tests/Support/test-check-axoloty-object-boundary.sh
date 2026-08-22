#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Negative self-test for the G3 boundary checker. A tiny synthetic package
# fixture keeps this harness runnable before the production G3 packages land.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-axoloty-object-boundary.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

write_fixture() {
    rm -rf "$tmp/Packages" "$tmp/Embedded"
    mkdir -p \
        "$tmp/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel" \
        "$tmp/Packages/AxolotyObjectMacros/Sources/AxolotyObjectMacros" \
        "$tmp/Packages/AxolotyObjectMacros/Sources/AxolotyObjectMacrosImplementation" \
        "$tmp/Embedded/swift/components/axoloty_object_model"
    printf '%s\n' '# fixture' > "$tmp/Packages/AxolotyObjectModel/AGENTS.md"
    printf '%s\n' '# fixture' > "$tmp/Packages/AxolotyObjectMacros/AGENTS.md"
    printf '%s\n' \
        '// swift-tools-version:6.3' \
        'import PackageDescription' \
        'let package = Package(name: "AxolotyObjectModel", products: [.library(name: "AxolotyObjectModel", targets: ["AxolotyObjectModel"])], dependencies: [.package(path: "../AxolotyWire")], targets: [.target(name: "AxolotyObjectModel", path: "Sources/AxolotyObjectModel")])' \
        > "$tmp/Packages/AxolotyObjectModel/Package.swift"
    printf '%s\n' \
        '// swift-tools-version:6.3' \
        'import PackageDescription' \
        'let package = Package(name: "AxolotyObjectMacros", products: [.library(name: "AxolotyObjectMacros", targets: ["AxolotyObjectMacros"])], dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0")], targets: [.target(name: "AxolotyObjectMacros", dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax")], path: "Sources/AxolotyObjectMacros")])' \
        > "$tmp/Packages/AxolotyObjectMacros/Package.swift"
    printf '%s\n' '{"version":3,"pins":[]}' > "$tmp/Packages/AxolotyObjectModel/Package.resolved"
    printf '%s\n' '{"version":3,"pins":[{"identity":"swift-syntax","state":{"version":"603.0.0"}}]}' > "$tmp/Packages/AxolotyObjectMacros/Package.resolved"
    printf '%s\n' 'struct FixtureObjectModel {}' > "$tmp/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/Fixture.swift"
    printf '%s\n' 'import SwiftSyntax' > "$tmp/Packages/AxolotyObjectMacros/Sources/AxolotyObjectMacros/Fixture.swift"
    printf '%s\n' 'struct FixtureMacroImplementation {}' > "$tmp/Packages/AxolotyObjectMacros/Sources/AxolotyObjectMacrosImplementation/Fixture.swift"
    printf '%s\n' \
        'file(GLOB AXOLOTY_OBJECT_MODEL_SOURCES "${AXOLOTY_ROOT}/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/*.swift")' \
        'idf_component_register_swift(${COMPONENT_LIB} SRCS ${AXOLOTY_OBJECT_MODEL_SOURCES})' \
        > "$tmp/Embedded/swift/components/axoloty_object_model/CMakeLists.txt"
}

run_checker() {
    AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/Packages/AxolotyObjectModel" \
    AXOLOTY_OBJECT_MACROS_PACKAGE_DIR="$tmp/Packages/AxolotyObjectMacros" \
    AXOLOTY_OBJECT_MODEL_COMPONENT_DIR="$tmp/Embedded/swift/components/axoloty_object_model" \
        "$checker"
}

expect_rejected() {
    label=$1
    mutation=$2
    write_fixture
    printf '%s\n' "$mutation" >> "$tmp/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/Fixture.swift"
    if run_checker >/dev/null 2>&1; then
        echo "error: checker accepted $label boundary" >&2
        exit 1
    fi
}

expect_macro_rejected() {
    label=$1
    mutation=$2
    write_fixture
    printf '%s\n' "$mutation" >> "$tmp/Packages/AxolotyObjectMacros/Sources/AxolotyObjectMacrosImplementation/Fixture.swift"
    if run_checker >/dev/null 2>&1; then
        echo "error: checker accepted nested macro $label boundary" >&2
        exit 1
    fi
}

write_fixture
run_checker >/dev/null
expect_rejected "Foundation" "import Foundation"
expect_rejected "MQTT" "import MQTTNIO"
expect_rejected "NIO" "import NIOCore"
expect_rejected "logging" "import Logging"
expect_rejected "global actor" "@MainActor struct HostFacade {}"
expect_rejected "actor" "actor ForbiddenActor {}"
expect_rejected "controller" "struct ForbiddenController {}"
expect_rejected "lifecycle" "struct ForbiddenLifecycle {}"
expect_rejected "Array" "let values: Array<Int>"
expect_rejected "Dictionary" "let values: Dictionary<String, Int>"
expect_rejected "global mutable registry" "static var globalRegistry = 0"
expect_macro_rejected "Foundation" "import Foundation"

write_fixture
printf '%s\n' ' .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),' >> "$tmp/Packages/AxolotyObjectModel/Package.swift"
if run_checker >/dev/null 2>&1; then
    echo "error: checker accepted forbidden manifest dependency" >&2
    exit 1
fi

write_fixture
sed -i '/Packages\/AxolotyObjectModel/d' "$tmp/Embedded/swift/components/axoloty_object_model/CMakeLists.txt"
if run_checker >/dev/null 2>&1; then
    echo "error: checker accepted missing source inclusion" >&2
    exit 1
fi

echo "AxolotyObjectModel boundary negative tests passed"
