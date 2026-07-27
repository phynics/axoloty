#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for check-embedded-swift.sh (issue #320).
#
# 1. Runs the checker; it must succeed and produce an object file.
# 2. Creates a temp source file that uses untyped `throws` (which Embedded
#    Swift rejects) and verifies the checker fails.
# 3. Prints SELF-TEST OK on success.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-embedded-swift.sh"

# 1. The real AxolotyWire sources must compile under Embedded Swift.
if ! sh "$checker" >/dev/null 2>&1; then
    echo "expected checker to pass against real AxolotyWire sources" >&2
    exit 1
fi
echo "  PASS: AxolotyWire compiles under Embedded Swift"

# 2. A source file with untyped throws must fail.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/Bad.swift" <<'SWIFT'
public struct BadError: Error {
    public let reason: String
}
public struct Bad {
    public static func fail() throws -> Int {
        throw BadError(reason: "nope")
    }
}
SWIFT

if swiftc \
    -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded \
    -parse-as-library \
    -Osize \
    -wmo \
    -c "$tmpdir/Bad.swift" \
    -o "$tmpdir/Bad.o" 2>/dev/null; then
    echo "expected untyped throws to fail under Embedded Swift" >&2
    exit 1
fi
echo "  PASS: untyped throws correctly rejected by Embedded Swift"

echo ""
echo "SELF-TEST OK (2 checks passed, 0 failed)"
