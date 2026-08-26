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

check "benchmark keeps the single-tokenizer implementation guard" \
    grep -q "WireReader must construct one tokenizer" "$SCRIPT_DIR/check-benchmark-wire-bounds.sh"

wire_bounds="$SCRIPT_DIR/../../Packages/AxolotyWire/Tests/AxolotyWireTests/WireBoundsTests.swift"

check "WireBoundsTests.swift exists" test -f "$wire_bounds"

check "WireBoundsTests.swift has copyright header" grep -q "Copyright (c) 2026 Atakan DULKER" "$wire_bounds"

check "WireBoundsTests.swift keeps parser-work assertion deterministic" grep -q "ParserWorkBoundsTests" "$wire_bounds"

check "WireBoundsTests.swift leaves wall-clock evidence to benchmarks" sh -c '! grep -qE "ContinuousClock|linearWorkScaling" "$1"' _ "$wire_bounds"

check "WireBoundsTests.swift asserts behavior without source inspection" \
    sh -c '! grep -qE "#filePath|WireReader\\.swift" "$1"' _ "$wire_bounds"

echo
echo "SELF-TEST OK ($pass checks passed, $fail_count failed)"
[ "$fail_count" -eq 0 ] || exit 1
