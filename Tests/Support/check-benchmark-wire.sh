#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Wire benchmark orchestration for issue #300.
#
# Runs the WireBenchmark executable 5 times with CPU pinning (taskset),
# computes p50/p95 per case+operation, checks noise (MAD ≤ 5%), runs
# heaptrack allocation profiling (if available), and compares against
# the checked-in baseline.
#
# Runs inside the base dev container (IMAGE=axoloty-dev).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="${BENCHMARK_OUTPUT_DIR:-$SCRIPT_DIR/.testing/benchmarks/$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BASELINE_FILE="$SCRIPT_DIR/Benchmarks/Baselines/wire-baseline.json"
RUNS=5

mkdir -p "$OUT_DIR"

# --- Environment checks ------------------------------------------------------

fail() {
    echo "BENCHMARK WIRE FAIL: $1" >&2
    exit 1
}

echo "== Environment =="

# CPU pinning.
if ! command -v taskset >/dev/null 2>&1; then
    fail "taskset not found (install util-linux)"
fi
CPU_GOVERNOR="unknown"
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
fi
echo "taskset: available"
echo "cpu governor: $CPU_GOVERNOR"

# Heaptrack.
HAVE_HEAPTRACK=false
if command -v heaptrack >/dev/null 2>&1; then
    HAVE_HEAPTRACK=true
    echo "heaptrack: available"
else
    echo "heaptrack: not available (allocation profiling will be skipped)"
fi

# --- Latency benchmark (5 runs) ----------------------------------------------

BINARY="WireBenchmark"
BINARY_PATH="$SCRIPT_DIR/.build/release/$BINARY"

# Build in release mode if not already built.
if [ ! -x "$BINARY_PATH" ]; then
    echo "== Building WireBenchmark (release) =="
    (cd "$SCRIPT_DIR" && swift build -c release --product WireBenchmark) || fail "release build failed"
fi

echo "== Latency benchmark ($RUNS runs) =="

run_files=""
for run in $(seq 1 $RUNS); do
    run_file="$OUT_DIR/run-${run}.json"
    echo "  run $run/$RUNS..."
    taskset -c 0 "$BINARY_PATH" > "$run_file" 2>/dev/null || fail "run $run failed"
    run_files="$run_files $run_file"
done

# --- Aggregate p50/p95 and check noise ---------------------------------------

echo "== Aggregating results =="

AGGREGATED=$(python3 - "$OUT_DIR" <<'PYEOF'
import json, sys, os, statistics

out_dir = sys.argv[1]
runs = []
for i in range(1, 6):
    path = os.path.join(out_dir, f"run-{i}.json")
    with open(path) as f:
        runs.append(json.load(f))

env = runs[0].get("environment", {})
cases = runs[0].get("cases", [])

def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0
    k = (len(sorted_vals) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return sorted_vals[f]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)

def mad(vals):
    if not vals:
        return 0
    med = statistics.median(vals)
    return statistics.median([abs(v - med) for v in vals])

result_cases = []
noisy_cases = []

for case_idx, case in enumerate(cases):
    cid = case["caseId"]
    family = case["family"]
    size_class = case["sizeClass"]
    ops = case.get("operations", {})
    result_ops = {}

    for op_name, op_data in ops.items():
        samples = op_data.get("samplesNs", [])
        batch_size = op_data.get("batchSize", 1)

        # p50/p95 per run.
        run_p50s = []
        run_p95s = []
        for run in runs:
            run_case = run["cases"][case_idx]
            run_op = run_case["operations"][op_name]
            run_samples = sorted(run_op["samplesNs"])
            run_p50s.append(percentile(run_samples, 50))
            run_p95s.append(percentile(run_samples, 95))

        # Aggregate: median of the 5 runs' p50/p95.
        final_p50 = int(statistics.median(run_p50s))
        final_p95 = int(statistics.median(run_p95s))

        # Noise: relative MAD of p50 across runs.
        p50_mad = mad(run_p50s)
        if final_p50 > 0 and p50_mad / final_p50 > 0.05:
            noisy_cases.append(f"{cid}.{op_name}")

        result_ops[op_name] = {
            "p50ns": final_p50,
            "p95ns": final_p95,
            "batchSize": batch_size,
        }

    result_cases.append({
        "caseId": cid,
        "family": family,
        "sizeClass": size_class,
        "operations": result_ops,
    })

output = {
    "environment": env,
    "cpuGovernor": os.environ.get("CPU_GOVERNOR", "unknown"),
    "cases": result_cases,
}

if noisy_cases:
    output["noisy"] = noisy_cases

print(json.dumps(output, indent=2))
PYEOF
)

echo "$AGGREGATED" > "$OUT_DIR/wire-baseline.json"

# Check for noisy results.
noisy=$(echo "$AGGREGATED" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('noisy',[])))")
if [ -n "$noisy" ]; then
    echo "BENCHMARK WIRE FAIL: noisy results (MAD > 5%):" >&2
    echo "$noisy" >&2
    exit 1
fi

# --- Allocation profiling (if heaptrack available) ---------------------------

if [ "$HAVE_HEAPTRACK" = "true" ]; then
    echo "== Heaptrack validation =="
    validation_output="$OUT_DIR/heaptrack-validation.json"
    heaptrack "$BINARY_PATH" --validate-allocations \
        --output "$OUT_DIR/heaptrack-validation" 2>/dev/null \
        | tee "$validation_output" || true

    echo "== Allocation profiling =="
    heaptrack "$BINARY_PATH" -o "$OUT_DIR/heaptrack-bench" 2>/dev/null || true
    echo "  (allocation results in $OUT_DIR/heaptrack-bench.*)"
else
    echo "== Allocation profiling skipped (heaptrack not available) =="
fi

# --- Baseline comparison -----------------------------------------------------

echo "== Baseline comparison =="

# Check if baseline is a template.
is_template=$(python3 -c "
import json, sys
try:
    with open('$BASELINE_FILE') as f:
        d = json.load(f)
    print('yes' if 'cases' not in d else 'no')
except: print('yes')
")

if [ "$is_template" = "yes" ]; then
    cp "$OUT_DIR/wire-baseline.json" "$BASELINE_FILE"
    echo "BASELINE CREATED at $BASELINE_FILE"
else
    # Compare.
    comparison=$(python3 - "$OUT_DIR/wire-baseline.json" "$BASELINE_FILE" <<'PYEOF'
import json, sys

new_path, base_path = sys.argv[1], sys.argv[2]
with open(new_path) as f: new = json.load(f)
with open(base_path) as f: base = json.load(f)

# Corpus hash must match.
new_hash = new.get("environment", {}).get("corpusHash", "")
base_hash = base.get("environment", {}).get("corpusHash", "")
if new_hash and base_hash and new_hash != base_hash:
    print(f"MISMATCH: corpus hash differs (new={new_hash}, base={base_hash})")
    sys.exit(1)

# Compare p50/p95 with ±10% tolerance.
diffs = []
new_cases = {c["caseId"]: c for c in new.get("cases", [])}
base_cases = {c["caseId"]: c for c in base.get("cases", [])}

for cid in sorted(new_cases.keys() | base_cases.keys()):
    if cid not in base_cases:
        diffs.append(f"  + {cid} (new case)")
        continue
    if cid not in new_cases:
        diffs.append(f"  - {cid} (removed case)")
        continue
    nc = new_cases[cid]["operations"]
    bc = base_cases[cid]["operations"]
    for op in sorted(nc.keys() | bc.keys()):
        if op not in bc:
            diffs.append(f"  + {cid}.{op} (new operation)")
            continue
        if op not in nc:
            diffs.append(f"  - {cid}.{op} (removed operation)")
            continue
        n50, b50 = nc[op]["p50ns"], bc[op]["p50ns"]
        n95, b95 = nc[op]["p95ns"], bc[op]["p95ns"]
        if b50 > 0 and abs(n50 - b50) / b50 > 0.10:
            diffs.append(f"  ~ {cid}.{op} p50: {b50} -> {n50}")
        if b95 > 0 and abs(n95 - b95) / b95 > 0.10:
            diffs.append(f"  ~ {cid}.{op} p95: {b95} -> {n95}")

if diffs:
    print("BASELINE DRIFT detected:")
    for d in diffs:
        print(d)
    sys.exit(1)
else:
    print("MATCH")
PYEOF
)
    if [ "$comparison" != "MATCH" ]; then
        echo "$comparison" >&2
        exit 1
    fi
    echo "Baseline matches within tolerance."
fi

echo "BENCHMARK WIRE OK"
