#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for the host wire hot-path allocation regression check (issue #490).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
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

check "check-benchmark-wire-allocation.sh passes sh -n" sh -n "$SCRIPT_DIR/check-benchmark-wire-allocation.sh"

check "WireAllocation probe source exists" test -f "$ROOT/Benchmarks/WireAllocation/main.swift"

check "WireAllocation target exists in Package.swift" \
    grep -q 'name: "WireAllocation"' "$ROOT/Package.swift"

check "probe runs a decode + dispatch hot path" \
    grep -q 'AssociateWireData(from: message.reader())' "$ROOT/Benchmarks/WireAllocation/main.swift"

check "probe dispatches through ProtocolProcessor" \
    grep -q 'processor.processInbound' "$ROOT/Benchmarks/WireAllocation/main.swift"

check "check script requires heaptrack" \
    grep -q 'command -v heaptrack' "$SCRIPT_DIR/check-benchmark-wire-allocation.sh"

check "Makefile has benchmark-wire-allocation target" \
    grep -q '^benchmark-wire-allocation:' "$ROOT/Makefile"

echo
echo "test-check-benchmark-wire-allocation: $pass passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
