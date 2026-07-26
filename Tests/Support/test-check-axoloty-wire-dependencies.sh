#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-axoloty-wire-dependencies.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

write_manifest() {
    cat >"$fixture/Package.swift"
}

write_source() {
    mkdir -p "$fixture/Source/WireCodec"
    cat >"$fixture/Source/WireCodec/Fixture.swift"
}

expect_failure() {
    if sh "$checker" "$fixture" >/dev/null 2>&1; then
        echo "expected AxolotyWire boundary checker to fail" >&2
        exit 1
    fi
}

write_manifest <<'EOF'
let package = Package(
    targets: [
        .target(
            name: "AxolotyWire",
            path: "Source/WireCodec"
        ),
    ]
)
EOF
write_source <<'EOF'
import Swift
EOF
sh "$checker" "$fixture"

write_manifest <<'EOF'
let package = Package(
    targets: [
        .target(
            name: "AxolotyWire",
            path: "Source/WireCodec",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
    ]
)
EOF
expect_failure

write_manifest <<'EOF'
let package = Package(targets: [.target(name: "AxolotyWire", path: "Source/Elsewhere")])
EOF
expect_failure

write_manifest <<'EOF'
let package = Package(targets: [.target(name: "AxolotyWire", path: "Source/WireCodec")])
EOF
write_source <<'EOF'
@preconcurrency import MQTTNIO
EOF
expect_failure

write_source <<'EOF'
internal import Axoloty
EOF
expect_failure

write_source <<'EOF'
let fixture = #"embedded \" quote and inert import Foundation"#
EOF
sh "$checker" "$fixture"

write_source <<'EOF'
let fixture = #"embedded \" quote"#
import Foundation
EOF
expect_failure
