#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Live-gated lifecycle matrix. Every result is retained as a manifest: executed
# scenarios have both application and MQTT-capture evidence; unavailable
# scenarios are explicitly ``unsupported`` and are never treated as passes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
HERE="$ROOT/Tests/WireCompatibility/Lifecycle/Live"
OUTPUT_ROOT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}/lifecycle"
SCENARIOS="${WIRE_LIFECYCLE_SCENARIOS:-offline-queueing reconnect-resubscribe broker-restart graceful-deadvertise unexpected-disconnect-last-will clean-session duplicate-reply late-reply qos-0 qos-1 qos-2}"
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-30}"

mkdir -p "$OUTPUT_ROOT"
for scenario in $SCENARIOS; do
    artifact_dir="$OUTPUT_ROOT/$scenario"
    mkdir -p "$artifact_dir"
    verifier_log="$artifact_dir/verifier.log"
    manifest="$artifact_dir/manifest.json"
    DEADLINE=$(( $(date +%s) + DEADLINE_SECONDS ))

    if [ "$scenario" = "unexpected-disconnect-last-will" ]; then
        WIRE_OUTPUT_DIR="$artifact_dir" "$HERE/run-coatyjs-last-will.sh" >"$verifier_log" 2>&1
        python3 "$HERE/lifecycle-matrix.py" "$scenario" \
            --application-log "$artifact_dir/coatyjs-last-will.application.jsonl" \
            --capture "$artifact_dir/coatyjs-last-will.jsonl" --output "$manifest"
    elif [ "$scenario" = "qos-0" ] || [ "$scenario" = "graceful-deadvertise" ]; then
        WIRE_OUTPUT_DIR="$artifact_dir" "$HERE/run-coatyjs-qos-scenario.sh" "$scenario" >"$verifier_log" 2>&1
        python3 "$HERE/lifecycle-matrix.py" "$scenario" \
            --application-log "$artifact_dir/coatyjs-$scenario.application.jsonl" \
            --capture "$artifact_dir/coatyjs-$scenario.jsonl" --output "$manifest"
    else
        python3 "$HERE/lifecycle-matrix.py" "$scenario" --output "$manifest" >"$verifier_log" 2>&1
    fi
    if [ "$(date +%s)" -gt "$DEADLINE" ]; then
        echo "Scenario exceeded its ${DEADLINE_SECONDS}s deadline: $scenario" >&2
        exit 1
    fi
    echo "Lifecycle manifest retained at $manifest"
done
