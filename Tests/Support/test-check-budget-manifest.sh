#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for the budget manifest validator (issue #303).
#
# Positive checks confirm the checked-in provisional manifest validates.
# Negative checks each build a tampered fixture and assert the validator
# REJECTS it, covering every rule enumerated in the issue: top-level keys,
# approval-state rules, the C-surrogate eligibility rule, device latency
# headroom, mandatory device metrics, source-run identifiers, sustained-rate
# capacity headroom, kill-gate counts, over-limit rejection, completion-gate
# counts, approvalStatus enumeration, host dependency closure, and partition
# safety.

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

# neg: assert the validator FAILS on the given fixture file.
neg() {
    desc=$1
    file=$2
    if ! "$SCRIPT_DIR/check-budget-manifest.sh" "$file" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (validator accepted an invalid manifest)"
        fail_count=$((fail_count + 1))
    fi
}

# ---------------------------------------------------------------------------
# Positive checks.
# ---------------------------------------------------------------------------
check "check-budget-manifest.sh passes sh -n" sh -n "$SCRIPT_DIR/check-budget-manifest.sh"
check "budget-manifest.json exists" test -f "$MANIFEST"
check "manifest validates" "$SCRIPT_DIR/check-budget-manifest.sh" "$MANIFEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Build an approved-valid base fixture: the provisional manifest with every
# approval gate satisfied. Approved-only negative tests mutate this base so
# they isolate a single rule rather than tripping the pending-baseline
# checks.
# ---------------------------------------------------------------------------
python3 - "$MANIFEST" "$TMP/approved-base.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
m["approvalStatus"] = "approved"
# Host latency: populate measured + budget values, mark ok.
for op, d in m["environments"]["host"]["latency"].items():
    d["p50ns"] = 1000
    d["p95ns"] = 2000
    d["budgetP50ns"] = 1500
    d["budgetP95ns"] = 3000
    d["headroomP50"] = 500
    d["headroomP95"] = 1000
    d["status"] = "ok"
# Host binary size: populate, mark ok.
for c, d in m["environments"]["host"]["binarySize"].items():
    d["unstrippedBytes"] = 100000
    d["strippedBytes"] = 50000
    d["status"] = "ok"
# Fingerprints: fill every key with a non-empty string.
for env in ["host", "esp32c6"]:
    for k in m["environments"][env]["fingerprint"]:
        m["environments"][env]["fingerprint"][k] = "test-fingerprint-value"
# Device approved evidence.
dev = m["environments"]["esp32c6"]
dev["sourceRun"] = "issue-322-embedded-swift-run-1"
dev["resources"]["sustainedRate"]["capacityHeadroomMsgPerS"] = 130
dev["resources"]["largestFreeBlock"] = {"measured": 200000, "budgetMin": 160000, "unit": "bytes"}
dev["resources"]["fragmentation"] = {"measured": 0, "budgetMax": 5, "unit": "percent"}
dev["resources"]["data"] = {"measured": 10000, "budgetMax": 12000, "unit": "bytes"}
dev["resources"]["bss"] = {"measured": 5000, "budgetMax": 6000, "unit": "bytes"}
dev["resources"]["iram"] = {"measured": 2000, "budgetMax": 2500, "unit": "bytes"}
dev["hotPathAllocations"]["measured"] = 0
with open(sys.argv[2], "w") as f:
    json.dump(m, f)
PYEOF

# Sanity: the approved base must itself validate (else the isolation is broken).
check "approved-base fixture validates" "$SCRIPT_DIR/check-budget-manifest.sh" "$TMP/approved-base.json"

echo "  -- negative cases (provisional-manifest mutations) --"

# 1. Missing moduleApiVersion.
python3 - "$MANIFEST" "$TMP/01-missing-moduleApiVersion.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
del m["moduleApiVersion"]
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "missing moduleApiVersion fails" "$TMP/01-missing-moduleApiVersion.json"

# 4. C surrogate marked approval-eligible (must fail regardless of status).
python3 - "$MANIFEST" "$TMP/04-csurrogate-approved.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["historicalEvidence"]["esp32c6-c-surrogate"]["approvalEligible"] = True
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "C surrogate approvalEligible=true fails" "$TMP/04-csurrogate-approved.json"

# 5. Device latency with no p95 headroom (budgetP95us == measuredP95us).
python3 - "$MANIFEST" "$TMP/05-no-p95-headroom.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["environments"]["esp32c6"]["latency"]["topicParse"]["budgetP95us"] = 2
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "device latency budgetP95us <= measuredP95us fails" "$TMP/05-no-p95-headroom.json"

# 9. Missing kill gate: <5 entry-evidence gates.
python3 - "$MANIFEST" "$TMP/09-missing-entry-gate.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["phase4EntryEvidenceGates"].pop()
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "phase4EntryEvidenceGates < 5 fails" "$TMP/09-missing-entry-gate.json"

# 10. Hard-coded over-limit success record.
python3 - "$MANIFEST" "$TMP/10-over-limit-not-rejected.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["environments"]["esp32c6"]["sizeLimits"]["maxPayloadSize"]["overLimitRejected"] = False
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "sizeLimits overLimitRejected=false fails" "$TMP/10-over-limit-not-rejected.json"

# 11. Completion gates with missing cases: <4 gates.
python3 - "$MANIFEST" "$TMP/11-completion-gates-too-few.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["phase4CompletionGates"].pop()
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "phase4CompletionGates < 4 fails" "$TMP/11-completion-gates-too-few.json"

# 12. approvalStatus invalid value.
python3 - "$MANIFEST" "$TMP/12-invalid-approval-status.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["approvalStatus"] = "approved-but-todo"
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "approvalStatus invalid value fails" "$TMP/12-invalid-approval-status.json"

# 13. Host dependency closure non-empty for AxolotyWireConsumer.
python3 - "$MANIFEST" "$TMP/13-wire-hostdeps-nonempty.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["environments"]["host"]["dependencyClosure"]["AxolotyWireConsumer"]["hostDeps"] = ["mqtt-nio"]
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "AxolotyWireConsumer.hostDeps non-empty fails" "$TMP/13-wire-hostdeps-nonempty.json"

# 14. Partition safety: flashImage budgetMax >= partitionLimitBytes.
python3 - "$MANIFEST" "$TMP/14-partition-unsafe.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
flash = m["environments"]["esp32c6"]["resources"]["flashImage"]
flash["budgetMax"] = flash["partitionLimitBytes"]
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "flashImage budgetMax >= partitionLimitBytes fails" "$TMP/14-partition-unsafe.json"

echo "  -- negative cases (approved-base mutations) --"

# 2. approved + host latency pending-baseline.
python3 - "$TMP/approved-base.json" "$TMP/02-approved-host-latency-pending.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["environments"]["host"]["latency"]["topicParse"]["status"] = "pending-baseline"
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "approved + host latency pending-baseline fails" "$TMP/02-approved-host-latency-pending.json"

# 3. approved + host binarySize pending-baseline.
python3 - "$TMP/approved-base.json" "$TMP/03-approved-host-binarysize-pending.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["environments"]["host"]["binarySize"]["AxolotyWireConsumer"]["status"] = "pending-baseline"
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "approved + host binarySize pending-baseline fails" "$TMP/03-approved-host-binarysize-pending.json"

# 6. approved + missing largestFreeBlock resource.
python3 - "$TMP/approved-base.json" "$TMP/06-approved-missing-largestfreeblock.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
del m["environments"]["esp32c6"]["resources"]["largestFreeBlock"]
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "approved + missing largestFreeBlock fails" "$TMP/06-approved-missing-largestfreeblock.json"

# 7. approved + device measurement missing sourceRun.
python3 - "$TMP/approved-base.json" "$TMP/07-approved-missing-source-run.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["environments"]["esp32c6"]["sourceRun"] = None
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "approved + device missing sourceRun fails" "$TMP/07-approved-missing-source-run.json"

# 8. approved + sustained-rate without capacity headroom >= 125.
python3 - "$TMP/approved-base.json" "$TMP/08-approved-no-rate-capacity.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
m["environments"]["esp32c6"]["resources"]["sustainedRate"]["capacityHeadroomMsgPerS"] = 100
with open(sys.argv[2], "w") as f: json.dump(m, f)
PYEOF
neg "approved + sustainedRate capacity < 125 fails" "$TMP/08-approved-no-rate-capacity.json"

echo
echo "SELF-TEST OK ($pass passed, $fail_count failed)"
[ "$fail_count" -eq 0 ] || exit 1
