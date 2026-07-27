#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for the budget manifest validator (issue #303).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/../../Benchmarks/Baselines/budget-manifest.json"
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

check "check-budget-manifest.sh passes sh -n" sh -n "$SCRIPT_DIR/check-budget-manifest.sh"

check "budget-manifest.json exists" test -f "$MANIFEST"

check "manifest validates" "$SCRIPT_DIR/check-budget-manifest.sh" "$MANIFEST"

# Test that a tampered manifest fails.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
# Remove a required key.
del m['noisePolicy']
with open('$TMP/bad-manifest.json', 'w') as f:
    json.dump(m, f)
"
check "tampered manifest (missing noisePolicy) fails" sh -c "! '$SCRIPT_DIR/check-budget-manifest.sh' '$TMP/bad-manifest.json' 2>/dev/null"

# Test that a manifest with budget == measured (no headroom) fails.
python3 -c "
import json
with open('$MANIFEST') as f:
    m = json.load(f)
m['environments']['esp32c6']['resources']['freeHeap']['budgetMin'] = 458684
with open('$TMP/no-headroom.json', 'w') as f:
    json.dump(m, f)
"
check "manifest with no headroom fails" sh -c "! '$SCRIPT_DIR/check-budget-manifest.sh' '$TMP/no-headroom.json' 2>/dev/null"

echo
echo "SELF-TEST OK ($pass checks passed, $fail_count failed)"
[ "$fail_count" -eq 0 ] || exit 1
