#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for the wire bounds benchmark orchestration (issue #301).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
pass=0
fail_count=0

check() {
    desc=$1
    shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail_count=$((fail_count + 1))
    fi
}

check "check-benchmark-wire-bounds.sh passes sh -n" sh -n "$SCRIPT_DIR/check-benchmark-wire-bounds.sh"

check "WireBoundsTests.swift exists" test -f "$SCRIPT_DIR/../AxolotyWire/WireBoundsTests.swift"

check "WireBoundsTests.swift has copyright header" grep -q "Copyright (c) 2026 Atakan DULKER" "$SCRIPT_DIR/../AxolotyWire/WireBoundsTests.swift"

echo
echo "SELF-TEST OK ($pass checks passed, $fail_count failed)"
[ "$fail_count" -eq 0 ] || exit 1
