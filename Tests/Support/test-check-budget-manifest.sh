#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Self-test for the budget manifest validator (issue #303).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST="$SCRIPT_DIR/../../Benchmarks/Baselines/budget-manifest.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail_count=0

check() {
    description=$1
    shift
    if "$@"; then
        echo "  PASS: $description"
        pass=$((pass + 1))
    else
        echo "  FAIL: $description"
        fail_count=$((fail_count + 1))
    fi
}

neg() {
    description=$1
    file=$2
    if ! "$SCRIPT_DIR/check-budget-manifest.sh" "$file" >/dev/null 2>&1; then
        echo "  PASS: $description"
        pass=$((pass + 1))
    else
        echo "  FAIL: $description (validator accepted an invalid manifest)"
        fail_count=$((fail_count + 1))
    fi
}

check "check-budget-manifest.sh passes sh -n" sh -n "$SCRIPT_DIR/check-budget-manifest.sh"
check "budget-manifest.json exists" test -f "$MANIFEST"
check "manifest validates" "$SCRIPT_DIR/check-budget-manifest.sh" "$MANIFEST"
node "$SCRIPT_DIR/budget-test-fixtures.mjs" "$MANIFEST" "$TMP"
check "approved-base fixture validates" "$SCRIPT_DIR/check-budget-manifest.sh" "$TMP/approved-base.json"

echo "  -- negative cases (provisional-manifest mutations) --"
neg "missing moduleApiVersion fails" "$TMP/01-missing-moduleApiVersion.json"
neg "C surrogate approvalEligible=true fails" "$TMP/04-csurrogate-approved.json"
neg "device latency budgetP95us <= measuredP95us fails" "$TMP/05-no-p95-headroom.json"
neg "phase4EntryEvidenceGates < 5 fails" "$TMP/09-missing-entry-gate.json"
neg "sizeLimits overLimitRejected=false fails" "$TMP/10-over-limit-not-rejected.json"
neg "phase4CompletionGates < 4 fails" "$TMP/11-completion-gates-too-few.json"
neg "approvalStatus invalid value fails" "$TMP/12-invalid-approval-status.json"
neg "AxolotyWireConsumer.hostDeps non-empty fails" "$TMP/13-wire-hostdeps-nonempty.json"
neg "flashImage budgetMax >= partitionLimitBytes fails" "$TMP/14-partition-unsafe.json"

echo "  -- negative cases (approved-base mutations) --"
neg "approved + host latency pending-baseline fails" "$TMP/02-approved-host-latency-pending.json"
neg "approved + host binarySize pending-baseline fails" "$TMP/03-approved-host-binarysize-pending.json"
neg "approved + missing largestFreeBlock fails" "$TMP/06-approved-missing-largestfreeblock.json"
neg "approved + device missing sourceRun fails" "$TMP/07-approved-missing-source-run.json"
neg "approved + sustainedRate capacity < 125 fails" "$TMP/08-approved-no-rate-capacity.json"

echo
echo "SELF-TEST OK ($pass passed, $fail_count failed)"
[ "$fail_count" -eq 0 ]
