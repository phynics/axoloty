#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates the budget manifest structure and completeness (issue #303).
#
# Checks that the manifest has all required keys, device budgets have
# explicit headroom (budget > measured), host budgets are either
# populated or marked pending-baseline, and Phase 4 kill gates are defined.

set -eu

manifest="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)/Benchmarks/Baselines/budget-manifest.json}"

fail() {
    echo "BUDGET MANIFEST FAIL: $1" >&2
    exit 1
}

if [ ! -f "$manifest" ]; then
    fail "manifest not found at $manifest"
fi

python3 - "$manifest" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    m = json.load(f)

errors = []

# Top-level keys.
for key in ["version", "corpusVersion", "moduleApiVersion", "noisePolicy",
            "regressionPolicy", "environments", "phase4KillGates"]:
    if key not in m:
        errors.append(f"missing top-level key: {key}")

# Noise policy.
np = m.get("noisePolicy", {})
for key in ["relativeMAD", "allocationVariance", "runs", "samplesPerRun"]:
    if key not in np:
        errors.append(f"noisePolicy missing: {key}")
if np.get("allocationVariance") != "exact-zero":
    errors.append("noisePolicy.allocationVariance must be 'exact-zero'")

# Regression policy.
rp = m.get("regressionPolicy", {})
for key in ["matchingFingerprintOnly", "noisyRunsFailCollection",
            "budgetIncreasesRequireEvidence", "failedBudgetsOpenFinding",
            "zeroAllocationHotPaths"]:
    if key not in rp:
        errors.append(f"regressionPolicy missing: {key}")

# Environments.
envs = m.get("environments", {})
for env_name in ["host", "esp32c6"]:
    if env_name not in envs:
        errors.append(f"environments missing: {env_name}")
        continue
    env = envs[env_name]
    for key in ["compiler", "optimization"]:
        if key not in env:
            errors.append(f"environments.{env_name} missing: {key}")

# Host: latency, binarySize, dependencyClosure.
host = envs.get("host", {})
for key in ["latency", "binarySize", "dependencyClosure"]:
    if key not in host:
        errors.append(f"environments.host missing: {key}")

# Host latency: each op must have status.
for op, data in host.get("latency", {}).items():
    if "status" not in data:
        errors.append(f"host.latency.{op} missing: status")

# Host binarySize: each consumer must have status.
for consumer, data in host.get("binarySize", {}).items():
    if "status" not in data:
        errors.append(f"host.binarySize.{consumer} missing: status")

# Host dependencyClosure: AxolotyWireConsumer must have empty hostDeps.
awc = host.get("dependencyClosure", {}).get("AxolotyWireConsumer", {})
if awc.get("hostDeps") != []:
    errors.append("host.dependencyClosure.AxolotyWireConsumer.hostDeps must be empty")

# ESP32-C6: latency, resources, sizeLimits.
dev = envs.get("esp32c6", {})
for key in ["latency", "resources", "sizeLimits"]:
    if key not in dev:
        errors.append(f"environments.esp32c6 missing: {key}")

# Device latency: each op must have measured and budget values, budget > measured.
for op, data in dev.get("latency", {}).items():
    for field in ["measuredP50us", "measuredP95us", "budgetP50us", "budgetP95us"]:
        if field not in data:
            errors.append(f"esp32c6.latency.{op} missing: {field}")
    m50 = data.get("measuredP50us", 0)
    b50 = data.get("budgetP50us", 0)
    if b50 > 0 and m50 > 0 and b50 <= m50:
        errors.append(f"esp32c6.latency.{op}: budgetP50us ({b50}) must be > measuredP50us ({m50})")

# Device resources: each must have measured and budgetMin/budgetMax.
for res, data in dev.get("resources", {}).items():
    if "measured" not in data:
        errors.append(f"esp32c6.resources.{res} missing: measured")
    if "budgetMin" not in data and "budgetMax" not in data:
        errors.append(f"esp32c6.resources.{res} missing: budgetMin or budgetMax")
    # Check headroom: budgetMin must be < measured (leave headroom).
    measured = data.get("measured", 0)
    budget_min = data.get("budgetMin", 0)
    if budget_min > 0 and measured > 0 and budget_min >= measured:
        errors.append(f"esp32c6.resources.{res}: budgetMin ({budget_min}) must be < measured ({measured}) for headroom")

# Device sizeLimits: each must have limit and overLimitRejected.
for lim, data in dev.get("sizeLimits", {}).items():
    if "limit" not in data:
        errors.append(f"esp32c6.sizeLimits.{lim} missing: limit")
    if "overLimitRejected" not in data:
        errors.append(f"esp32c6.sizeLimits.{lim} missing: overLimitRejected")
    if not data.get("overLimitRejected"):
        errors.append(f"esp32c6.sizeLimits.{lim}: overLimitRejected must be true")

# Phase 4 kill gates: must have at least 5, each with id and threshold.
gates = m.get("phase4KillGates", [])
if len(gates) < 5:
    errors.append(f"phase4KillGates must have at least 5 gates, got {len(gates)}")
for gate in gates:
    if "id" not in gate:
        errors.append("phase4KillGates: gate missing id")
    if "threshold" not in gate:
        errors.append(f"phase4KillGates.{gate.get('id', '?')}: missing threshold")

if errors:
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)

print("BUDGET MANIFEST OK")
PYEOF

if [ $? -ne 0 ]; then
    fail "validation failed (see errors above)"
fi
