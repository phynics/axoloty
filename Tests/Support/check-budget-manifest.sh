#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates the budget manifest structure and approval state (issue #303).
#
# Enforces the provisional/approved schema: required top-level keys, the
# historicalEvidence C-surrogate rule (never approval-eligible), host
# dependency closure, device latency headroom, device resource budgets,
# exact-zero hot-path allocation, partition safety, kill-gate counts and
# shape, numeric typing, and fingerprint completeness. Approval-state rules
# (pending-baseline, source-run, capacity headroom, mandatory device
# metrics, non-empty fingerprints) only fail the manifest when
# approvalStatus == "approved"; provisional manifests may carry null/empty
# pending fields.
#
# NOTE: this validator is stateless. A mismatched environment fingerprint
# (manifest vs. a recorded baseline) is reported by the benchmark harness,
# not here — and a mismatch must never fail or overwrite an existing
# matching-fingerprint baseline. That policy lives in the harness, not in
# this structural check.

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


def is_int(v):
    # Reject bools (Python bool is an int subclass) and strings.
    return isinstance(v, int) and not isinstance(v, bool)


# ---------------------------------------------------------------------------
# Top-level keys.
# ---------------------------------------------------------------------------
required_top = ["version", "corpusVersion", "moduleApiVersion", "approvalStatus",
                "noisePolicy", "regressionPolicy", "environments",
                "historicalEvidence", "phase4EntryEvidenceGates",
                "phase4CompletionGates"]
for key in required_top:
    if key not in m:
        errors.append(f"missing top-level key: {key}")

# version / corpusVersion / moduleApiVersion typing.
for key in ["version", "corpusVersion"]:
    if key in m and not is_int(m[key]):
        errors.append(f"{key} must be an integer")
if "moduleApiVersion" in m and not isinstance(m.get("moduleApiVersion"), str):
    errors.append("moduleApiVersion must be a string")

# approvalStatus.
status = m.get("approvalStatus")
if status not in ("provisional", "approved"):
    errors.append(f"approvalStatus must be 'provisional' or 'approved', got {status!r}")
approved = (status == "approved")

# ---------------------------------------------------------------------------
# Noise policy.
# ---------------------------------------------------------------------------
np = m.get("noisePolicy", {})
for key in ["relativeMAD", "allocationVariance", "runs", "samplesPerRun"]:
    if key not in np:
        errors.append(f"noisePolicy missing: {key}")
if np.get("allocationVariance") != "exact-zero":
    errors.append("noisePolicy.allocationVariance must be 'exact-zero'")
if "runs" in np and not is_int(np["runs"]):
    errors.append("noisePolicy.runs must be an integer")
if "samplesPerRun" in np and not is_int(np["samplesPerRun"]):
    errors.append("noisePolicy.samplesPerRun must be an integer")

# ---------------------------------------------------------------------------
# Regression policy.
# ---------------------------------------------------------------------------
rp = m.get("regressionPolicy", {})
for key in ["matchingFingerprintOnly", "noisyRunsFailCollection",
            "budgetIncreasesRequireEvidence", "failedBudgetsOpenFinding",
            "zeroAllocationHotPaths"]:
    if key not in rp:
        errors.append(f"regressionPolicy missing: {key}")
if rp.get("zeroAllocationHotPaths") != "exact-zero":
    errors.append("regressionPolicy.zeroAllocationHotPaths must be 'exact-zero'")

# ---------------------------------------------------------------------------
# historicalEvidence — C surrogate is NEVER approval-eligible, regardless
# of approvalStatus. This is the rule that makes the prior invalid Phase 3
# closure machine-checkable.
# ---------------------------------------------------------------------------
he = m.get("historicalEvidence", {})
if "esp32c6-c-surrogate" not in he:
    errors.append("historicalEvidence missing: esp32c6-c-surrogate")
else:
    cs = he["esp32c6-c-surrogate"]
    if cs.get("approvalEligible") is True:
        errors.append("historicalEvidence.esp32c6-c-surrogate.approvalEligible "
                      "must be false (C surrogate is never approval-eligible)")
    if cs.get("supersededBy") != "#322":
        errors.append("historicalEvidence.esp32c6-c-surrogate.supersededBy must be '#322'")
    if not isinstance(cs.get("description"), str) or not cs.get("description"):
        errors.append("historicalEvidence.esp32c6-c-surrogate.description must be non-empty")
# Any historical evidence entry claiming approval eligibility is a defect.
for name, entry in he.items():
    if isinstance(entry, dict) and entry.get("approvalEligible") is True:
        errors.append(f"historicalEvidence.{name}.approvalEligible must be false")

# ---------------------------------------------------------------------------
# Environments.
# ---------------------------------------------------------------------------
envs = m.get("environments", {})
for env_name in ["host", "esp32c6"]:
    if env_name not in envs:
        errors.append(f"environments missing: {env_name}")
        continue
    env = envs[env_name]
    for key in ["compiler", "optimization"]:
        if key not in env:
            errors.append(f"environments.{env_name} missing: {key}")
    # fingerprint object is required on every environment.
    if "fingerprint" not in env or not isinstance(env.get("fingerprint"), dict):
        errors.append(f"environments.{env_name} missing fingerprint object")
        fp = {}
    else:
        fp = env["fingerprint"]
        fp_keys = ["boardModel", "boardRevision", "cpuFrequencyMhz",
                   "swiftCompilerVersion", "idfSwiftVersion", "espIdfVersion",
                   "gccBinutilsVersion", "optimizationMode", "compilerFlags",
                   "containerImageDigest", "corpusVersion", "corpusHash",
                   "moduleApiVersion", "gitCommit", "gitClean",
                   "benchmarkHarnessVersion", "freeRtosTickRate",
                   "taskStackSizes"]
        for fk in fp_keys:
            if fk not in fp:
                errors.append(f"environments.{env_name}.fingerprint missing: {fk}")
        # Approval gate: every fingerprint key must be a non-empty string.
        if approved:
            for fk in fp_keys:
                v = fp.get(fk)
                if not isinstance(v, str) or v == "":
                    errors.append(
                        f"environments.{env_name}.fingerprint.{fk} must be a "
                        f"non-empty string when approved (got {v!r})")

# ---------------------------------------------------------------------------
# Host: latency, binarySize, dependencyClosure.
# ---------------------------------------------------------------------------
host = envs.get("host", {})
for key in ["latency", "binarySize", "dependencyClosure"]:
    if key not in host:
        errors.append(f"environments.host missing: {key}")

# Host latency.
numeric_fields_host = ["p50ns", "p95ns", "budgetP50ns", "budgetP95ns"]
for op, data in host.get("latency", {}).items():
    if "status" not in data:
        errors.append(f"host.latency.{op} missing: status")
    for field in numeric_fields_host:
        if field in data and data[field] is not None and not is_int(data[field]):
            errors.append(f"host.latency.{op}.{field} must be an integer or null")
    if approved:
        if data.get("status") == "pending-baseline":
            errors.append(f"host.latency.{op}: status is pending-baseline in approved manifest")
        if data.get("p50ns") is None:
            errors.append(f"host.latency.{op}: p50ns must be non-null when approved")
        if data.get("p95ns") is None:
            errors.append(f"host.latency.{op}: p95ns must be non-null when approved")
        if data.get("budgetP50ns") is None:
            errors.append(f"host.latency.{op}: budgetP50ns must be non-null when approved")
        if data.get("budgetP95ns") is None:
            errors.append(f"host.latency.{op}: budgetP95ns must be non-null when approved")

# Host binarySize.
for consumer, data in host.get("binarySize", {}).items():
    if "status" not in data:
        errors.append(f"host.binarySize.{consumer} missing: status")
    for field in ["unstrippedBytes", "strippedBytes"]:
        if field in data and data[field] is not None and not is_int(data[field]):
            errors.append(f"host.binarySize.{consumer}.{field} must be an integer or null")
    if approved:
        if data.get("status") == "pending-baseline":
            errors.append(f"host.binarySize.{consumer}: status is pending-baseline in approved manifest")
        if data.get("unstrippedBytes") is None:
            errors.append(f"host.binarySize.{consumer}: unstrippedBytes must be non-null when approved")
        if data.get("strippedBytes") is None:
            errors.append(f"host.binarySize.{consumer}: strippedBytes must be non-null when approved")

# Host dependency closure: AxolotyWireConsumer must have empty hostDeps.
awc = host.get("dependencyClosure", {}).get("AxolotyWireConsumer", {})
if awc.get("hostDeps") != []:
    errors.append("host.dependencyClosure.AxolotyWireConsumer.hostDeps must be empty")

# ---------------------------------------------------------------------------
# ESP32-C6: implementation, sourceRun, latency, resources, hotPathAllocations,
# sizeLimits.
# ---------------------------------------------------------------------------
dev = envs.get("esp32c6", {})

# implementation identifies the production implementation; the C surrogate
# is never approval-eligible, so an approved manifest must declare embedded-swift.
impl = dev.get("implementation")
if impl != "embedded-swift":
    if approved:
        errors.append("environments.esp32c6.implementation must be 'embedded-swift' when approved")
    elif impl is None:
        errors.append("environments.esp32c6 missing: implementation")
# sourceRun is required for approved device measurements; may be null provisional.
if approved:
    sr = dev.get("sourceRun")
    if not isinstance(sr, str) or sr == "":
        errors.append("environments.esp32c6.sourceRun must be a non-empty string when approved")

for key in ["latency", "resources", "sizeLimits"]:
    if key not in dev:
        errors.append(f"environments.esp32c6 missing: {key}")

# hotPathAllocations / allocationBudget: exact-zero budget. Key must always
# exist (provisional); when approved it must be present with budget == 0.
hpa = dev.get("hotPathAllocations")
if hpa is None and "allocationBudget" not in dev:
    errors.append("environments.esp32c6 missing: hotPathAllocations (or allocationBudget)")
elif hpa is not None:
    if not isinstance(hpa, dict):
        errors.append("environments.esp32c6.hotPathAllocations must be an object")
    else:
        if "budget" not in hpa:
            errors.append("environments.esp32c6.hotPathAllocations missing: budget")
        elif not is_int(hpa.get("budget")):
            errors.append("environments.esp32c6.hotPathAllocations.budget must be an integer")
        else:
            if hpa.get("budget") != 0:
                errors.append("environments.esp32c6.hotPathAllocations.budget must be exactly 0 (exact-zero)")
            if approved:
                if hpa.get("measured") is None or not is_int(hpa.get("measured")):
                    errors.append("environments.esp32c6.hotPathAllocations.measured must be an integer when approved")
                elif hpa.get("measured") != 0:
                    errors.append("environments.esp32c6.hotPathAllocations.measured must be exactly 0 when approved")

# Device latency: budget must exceed measured (when values present and non-null).
for op, data in dev.get("latency", {}).items():
    for field in ["measuredP50us", "measuredP95us", "budgetP50us", "budgetP95us"]:
        if field in data and data[field] is not None and not is_int(data[field]):
            errors.append(f"esp32c6.latency.{op}.{field} must be an integer or null")
    m50 = data.get("measuredP50us")
    b50 = data.get("budgetP50us")
    m95 = data.get("measuredP95us")
    b95 = data.get("budgetP95us")
    if m50 is not None and b50 is not None and is_int(m50) and is_int(b50) and b50 <= m50:
        errors.append(f"esp32c6.latency.{op}: budgetP50us ({b50}) must be > measuredP50us ({m50})")
    if m95 is not None and b95 is not None and is_int(m95) and is_int(b95) and b95 <= m95:
        errors.append(f"esp32c6.latency.{op}: budgetP95us ({b95}) must be > measuredP95us ({m95})")

# Device resources: measured + (budgetMin|budgetMax), headroom, numeric typing.
for res, data in dev.get("resources", {}).items():
    if "measured" not in data:
        errors.append(f"esp32c6.resources.{res} missing: measured")
    measured = data.get("measured")
    if measured is not None and not is_int(measured):
        errors.append(f"esp32c6.resources.{res}.measured must be an integer or null")
    has_min = "budgetMin" in data
    has_max = "budgetMax" in data
    if not has_min and not has_max:
        errors.append(f"esp32c6.resources.{res} missing: budgetMin or budgetMax")
    budget_min = data.get("budgetMin")
    budget_max = data.get("budgetMax")
    if budget_min is not None and not is_int(budget_min):
        errors.append(f"esp32c6.resources.{res}.budgetMin must be an integer or null")
    if budget_max is not None and not is_int(budget_max):
        errors.append(f"esp32c6.resources.{res}.budgetMax must be an integer or null")
    # Headroom (only when all relevant values are non-null ints).
    if has_min and is_int(budget_min) and is_int(measured) and budget_min >= measured:
        errors.append(f"esp32c6.resources.{res}: budgetMin ({budget_min}) must be < measured ({measured}) for headroom")
    if has_max and is_int(budget_max) and is_int(measured) and budget_max <= measured:
        errors.append(f"esp32c6.resources.{res}: budgetMax ({budget_max}) must be > measured ({measured}) for size budget")
    # Positive ranges where applicable.
    if is_int(measured) and measured < 0:
        errors.append(f"esp32c6.resources.{res}.measured must be >= 0")

# Partition safety for flashImage.
flash = dev.get("resources", {}).get("flashImage", {})
if flash:
    if "partitionLimitBytes" not in flash:
        errors.append("esp32c6.resources.flashImage missing: partitionLimitBytes")
    else:
        pl = flash.get("partitionLimitBytes")
        if not is_int(pl):
            errors.append("esp32c6.resources.flashImage.partitionLimitBytes must be an integer")
        bm = flash.get("budgetMax")
        fm = flash.get("measured")
        if is_int(bm) and is_int(pl) and bm >= pl:
            errors.append(f"esp32c6.resources.flashImage: budgetMax ({bm}) must be < partitionLimitBytes ({pl})")
        if is_int(bm) and is_int(fm) and bm <= fm:
            errors.append(f"esp32c6.resources.flashImage: budgetMax ({bm}) must be > measured ({fm})")

# Mandatory device metrics when approved.
required_device_resources = ["freeHeap", "minFreeHeap", "largestFreeBlock",
                             "fragmentation", "stackHighWater", "data",
                             "bss", "iram", "flashImage"]
if approved:
    dres = dev.get("resources", {})
    for r in required_device_resources:
        if r not in dres:
            errors.append(f"esp32c6.resources missing mandatory metric when approved: {r}")

# Sustained-rate capacity headroom: the 100 msg/s budget may only be
# approved when measured clean capacity >= 125 msg/s. Model this as a
# required capacityHeadroomMsgPerS field (>= 125) when approved.
sr = dev.get("resources", {}).get("sustainedRate", {})
if sr and approved:
    ch = sr.get("capacityHeadroomMsgPerS")
    if not is_int(ch) or ch < 125:
        errors.append(
            f"esp32c6.resources.sustainedRate.capacityHeadroomMsgPerS must be "
            f">= 125 when approved (got {ch!r})")

# Device sizeLimits: each must have limit and overLimitRejected == true.
for lim, data in dev.get("sizeLimits", {}).items():
    if "limit" not in data:
        errors.append(f"esp32c6.sizeLimits.{lim} missing: limit")
    elif not is_int(data.get("limit")):
        errors.append(f"esp32c6.sizeLimits.{lim}.limit must be an integer")
    if "overLimitRejected" not in data:
        errors.append(f"esp32c6.sizeLimits.{lim} missing: overLimitRejected")
    elif data.get("overLimitRejected") is not True:
        errors.append(f"esp32c6.sizeLimits.{lim}: overLimitRejected must be true")

# ---------------------------------------------------------------------------
# Phase 4 gate arrays.
# ---------------------------------------------------------------------------
def check_gates(gates, name, min_count):
    if not isinstance(gates, list):
        errors.append(f"{name} must be an array")
        return
    if len(gates) < min_count:
        errors.append(f"{name} must have at least {min_count} gates, got {len(gates)}")
    for gate in gates:
        if not isinstance(gate, dict):
            errors.append(f"{name}: gate must be an object")
            continue
        gid = gate.get("id")
        for field in ["id", "description", "threshold", "thresholdType"]:
            if field not in gate:
                errors.append(f"{name}: gate missing {field}")
        if "thresholdType" in gate and not isinstance(gate.get("thresholdType"), str):
            errors.append(f"{name}.{gid}: thresholdType must be a string")
        if "id" in gate and (not isinstance(gid, str) or gid == ""):
            errors.append(f"{name}: gate id must be a non-empty string")

check_gates(m.get("phase4EntryEvidenceGates", []), "phase4EntryEvidenceGates", 5)
check_gates(m.get("phase4CompletionGates", []), "phase4CompletionGates", 4)

if errors:
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)

print("BUDGET MANIFEST OK")
PYEOF

if [ $? -ne 0 ]; then
    fail "validation failed (see errors above)"
fi
