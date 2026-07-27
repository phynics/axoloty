#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates that AxolotyWire compiles under Embedded Swift for RISC-V
# (issue #320).
#
# Compiles every .swift file in Packages/AxolotyWire/Sources/AxolotyWire/
# with -target riscv32-none-none-eabi -enable-experimental-feature Embedded
# and reports the object file size. This catches any use of language
# features that Embedded Swift does not support (untyped throws, protocol
# existentials, dynamic dispatch, etc.) before they reach the device build.
#
# Usage: check-embedded-swift.sh
#   Runs inside the axoloty-dev container (needs swiftc on PATH).

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
wire_dir="$root/Packages/AxolotyWire/Sources/AxolotyWire"

if [ ! -d "$wire_dir" ]; then
    echo "FAIL: AxolotyWire source directory not found at $wire_dir" >&2
    exit 1
fi

# Collect all .swift files in the source directory.
swift_files=""
for f in "$wire_dir"/*.swift; do
    if [ -z "$swift_files" ]; then
        swift_files="$f"
    else
        swift_files="$swift_files $f"
    fi
done

if [ -z "$swift_files" ]; then
    echo "FAIL: no .swift files found in $wire_dir" >&2
    exit 1
fi

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

echo "Compiling AxolotyWire for riscv32-none-none-eabi (Embedded Swift)..."

if ! swiftc \
    -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded \
    -parse-as-library \
    -Osize \
    -wmo \
    -c $swift_files \
    -o "$tmpfile" 2>&1; then
    echo "FAIL: AxolotyWire does not compile under Embedded Swift" >&2
    exit 1
fi

size=$(wc -c < "$tmpfile")
echo "EMBEDDED SWIFT OK — riscv32 object: ${size} bytes"
