#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

for suite in BorrowedMessageTests WireCodecTests; do
    isolated="$root/Packages/AxolotyWire/Tests/AxolotyWireTests/$suite.swift"
    legacy="$root/Tests/WireCodec/$suite.swift"

    test -f "$isolated"
    test ! -e "$legacy"
    if rg -q '(^|[^A-Za-z])Axoloty([^A-Za-z]|$)' "$isolated"; then
        echo "error: $suite must not import or reference the Axoloty host module" >&2
        exit 1
    fi
done
