#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-axoloty-wire-dependencies.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# Each fixture mimics the AxolotyWire sub-package: a Package.swift plus
# Sources/AxolotyWire/ sources, rooted at the fixture directory.

write_manifest() {
    cat >"$fixture/Package.swift"
}

write_source() {
    mkdir -p "$fixture/Sources/AxolotyWire"
    cat >"$fixture/Sources/AxolotyWire/Fixture.swift"
}

expect_failure() {
    if sh "$checker" "$fixture" >/dev/null 2>&1; then
        echo "expected AxolotyWire boundary checker to fail" >&2
        exit 1
    fi
}

# Clean, dependency-free sub-package passes.
write_manifest <<'EOF'
let package = Package(
    name: "AxolotyWire",
    targets: [
        .target(name: "AxolotyWire", path: "Sources/AxolotyWire"),
    ]
)
EOF
write_source <<'EOF'
import Swift
EOF
sh "$checker" "$fixture"

# The approved exact-version `_JSONCore` package seam passes.
write_manifest <<'EOF'
let package = Package(
    name: "AxolotyWire",
    dependencies: [
        .package(
            url: "https://github.com/phynics/swift-json.git",
            exact: "2.5.3",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "AxolotyWire",
            dependencies: [
                .product(name: "IkigaJSONCore", package: "swift-json"),
            ],
            path: "Sources/AxolotyWire"
        ),
    ]
)
EOF
write_source <<'EOF'
import _JSONCore
EOF
sh "$checker" "$fixture"

# Target-level dependency is rejected.
write_manifest <<'EOF'
let package = Package(
    name: "AxolotyWire",
    targets: [
        .target(
            name: "AxolotyWire",
            path: "Sources/AxolotyWire",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
    ]
)
EOF
expect_failure

# Unapproved package-level dependency is rejected.
write_manifest <<'EOF'
let package = Package(
    name: "AxolotyWire",
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.2"),
    ],
    targets: [
        .target(name: "AxolotyWire", path: "Sources/AxolotyWire"),
    ]
)
EOF
expect_failure

# A different swift-json revision is rejected.
write_manifest <<'EOF'
let package = Package(
    name: "AxolotyWire",
    dependencies: [
        .package(
            url: "https://github.com/phynics/swift-json.git",
            revision: "unreviewed",
            traits: []
        ),
    ],
    targets: [
        .target(name: "AxolotyWire", path: "Sources/AxolotyWire"),
    ]
)
EOF
expect_failure

# Wrong source path is rejected.
write_manifest <<'EOF'
let package = Package(targets: [.target(name: "AxolotyWire", path: "Sources/Elsewhere")])
EOF
expect_failure

# Forbidden import with @preconcurrency is rejected.
write_manifest <<'EOF'
let package = Package(targets: [.target(name: "AxolotyWire", path: "Sources/AxolotyWire")])
EOF
write_source <<'EOF'
@preconcurrency import MQTTNIO
EOF
expect_failure

# Access-level import is rejected.
write_source <<'EOF'
internal import Axoloty
EOF
expect_failure

# Inert import inside a raw string is ignored.
write_source <<'EOF'
let fixture = #"embedded \" quote and inert import Foundation"#
EOF
sh "$checker" "$fixture"

# Real import after a raw string is rejected.
write_source <<'EOF'
let fixture = #"embedded \" quote"#
import Foundation
EOF
expect_failure
