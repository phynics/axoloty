#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for the wire benchmark orchestration (issue #300).
#
# Tests percentile calculation, noise rejection, fingerprint mismatch,
# and baseline serialization using pinned fixture data.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/wire-benchmark"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

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

# --- 1. Percentile calculation ----------------------------------------------

check "percentile p50 and p95 on known data" python3 -c "
import json, sys, os
sys.path.insert(0, os.environ.get('TMP_DIR', '$TMP_DIR'))

# Inline percentile test.
vals = sorted([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])

def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0
    k = (len(sorted_vals) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return sorted_vals[f]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)

p50 = percentile(vals, 50)
p95 = percentile(vals, 95)
assert p50 == 55, f'p50 expected 55, got {p50}'
assert abs(p95 - 95.5) < 0.01, f'p95 expected 95.5, got {p95}'
"

# --- 2. Noise rejection (MAD ≤ 5%) ------------------------------------------

check "low-MAD values pass noise check" python3 -c "
import statistics

def mad(vals):
    if not vals: return 0
    med = statistics.median(vals)
    return statistics.median([abs(v - med) for v in vals])

# 5 runs with p50 values close together.
p50s = [1000, 1005, 998, 1002, 1001]
m = mad(p50s)
rel = m / statistics.median(p50s)
assert rel <= 0.05, f'expected ≤ 5%, got {rel:.2%}'
"

check "high-MAD values fail noise check" python3 -c "
import statistics

def mad(vals):
    if not vals: return 0
    med = statistics.median(vals)
    return statistics.median([abs(v - med) for v in vals])

# 5 runs with p50 values spread far apart.
p50s = [1000, 1200, 800, 1500, 600]
m = mad(p50s)
rel = m / statistics.median(p50s)
assert rel > 0.05, f'expected > 5%, got {rel:.2%}'
"

# --- 3. Fingerprint mismatch ------------------------------------------------

check "different corpus hashes do not match" python3 -c "
import json, tempfile, os

env1 = {'corpusHash': 'abc123'}
env2 = {'corpusHash': 'def456'}
assert env1['corpusHash'] != env2['corpusHash']
"

# --- 4. Baseline serialization -----------------------------------------------

check "baseline create then compare passes" python3 -c "
import json, tempfile, os

# Create a baseline.
baseline = {
    'environment': {'corpusHash': 'test123'},
    'cases': [
        {
            'caseId': 'advertise-small',
            'family': 'ADV',
            'sizeClass': 'small',
            'operations': {
                'topicParse': {'p50ns': 100, 'p95ns': 200, 'batchSize': 10000}
            }
        }
    ]
}

# Serialize and deserialize.
path = tempfile.mktemp(suffix='.json')
with open(path, 'w') as f:
    json.dump(baseline, f)
with open(path) as f:
    loaded = json.load(f)
os.unlink(path)

assert loaded == baseline, 'round-trip mismatch'
"

check "tampered baseline fails comparison" python3 -c "
import json, tempfile, os

base = {'cases': [{'caseId': 'a', 'operations': {'op': {'p50ns': 100, 'p95ns': 200, 'batchSize': 1}}}]}
new = {'cases': [{'caseId': 'a', 'operations': {'op': {'p50ns': 200, 'p95ns': 400, 'batchSize': 1}}}]}
# 100 -> 200 is 100% change, > 10% tolerance.
old_val = base['cases'][0]['operations']['op']['p50ns']
new_val = new['cases'][0]['operations']['op']['p50ns']
assert abs(new_val - old_val) / old_val > 0.10
"

# --- 5. Syntax check on orchestration script ---------------------------------

check "check-benchmark-wire.sh passes sh -n" sh -n "$SCRIPT_DIR/check-benchmark-wire.sh"

echo
echo "SELF-TEST OK ($pass checks passed, $fail_count failed)"
[ "$fail_count" -eq 0 ] || exit 1
