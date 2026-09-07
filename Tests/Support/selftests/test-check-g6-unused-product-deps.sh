#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repository"
mkdir -p "$fixture/Tests/Support/checks" "$fixture/Tests/Support/evidence" "$fixture/Sources/Foo"
cp "$root/Tests/Support/checks/check-g6-unused-product-deps.sh" "$fixture/Tests/Support/checks/"
cp "$root/Tests/Support/evidence/validate-g6-unused-product-deps.mjs" "$fixture/Tests/Support/evidence/"
checker="$fixture/Tests/Support/checks/check-g6-unused-product-deps.sh"

package() {
    cat > "$fixture/Package.swift" <<EOF
// swift-tools-version:6.3
import PackageDescription
let package = Package(
    name: "Fixture",
    dependencies: [.package(url: "https://example.invalid/$2.git", from: "1.0.0")],
    targets: [
        .target(
            name: "Foo",
            dependencies: [.product(name: "$1", package: "$2")]
        )
    ]
)
EOF
}

package ErrorKit ErrorKit
printf 'import ErrorKit\n' > "$fixture/Sources/Foo/Foo.swift"
(cd "$fixture" && sh "$checker") >/dev/null

# A declared product nothing imports must fail the check.
printf '// no imports\n' > "$fixture/Sources/Foo/Foo.swift"
if (cd "$fixture" && sh "$checker") >/dev/null 2>&1; then
    echo "error: unused-product-dependency check accepted an unused product" >&2
    exit 1
fi

# A product declared under a name absent from the closed table must fail
# loudly rather than being silently skipped, even when it is imported.
package SomeUnmappedProduct fixture-dependency
printf 'import SomeUnmappedProduct\n' > "$fixture/Sources/Foo/Foo.swift"
if (cd "$fixture" && sh "$checker") >/dev/null 2>&1; then
    echo "error: unused-product-dependency check silently accepted an unmapped product" >&2
    exit 1
fi

echo "G6 unused product dependency negative self-test passed"
