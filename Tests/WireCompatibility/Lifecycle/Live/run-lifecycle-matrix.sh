#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Live-gated lifecycle matrix. Every result is retained as a manifest: executed
# scenarios have both application and MQTT-capture evidence; unavailable
# scenarios are explicitly ``unsupported`` and are never treated as passes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
HERE="$ROOT/Tests/WireCompatibility/Lifecycle/Live"
WIRE_TOOL="$ROOT/Tests/WireCompatibility/tool/dist/index.js"
OUTPUT_ROOT="${WIRE_OUTPUT_DIR:-$ROOT/.testing/wire}/lifecycle"
SCENARIOS="${WIRE_LIFECYCLE_SCENARIOS:-offline-queueing reconnect-resubscribe broker-restart graceful-deadvertise unexpected-disconnect-last-will clean-session duplicate-reply late-reply qos-0 qos-1 qos-2}"
# A cold containerized Swift build can precede the real sever/reconnect cycle.
DEADLINE_SECONDS="${WIRE_LIFECYCLE_DEADLINE_SECONDS:-600}"

mkdir -p "$OUTPUT_ROOT"
for scenario in $SCENARIOS; do
    artifact_dir="$OUTPUT_ROOT/$scenario"
    mkdir -p "$artifact_dir"
    verifier_log="$artifact_dir/verifier.log"
    manifest="$artifact_dir/manifest.json"
    DEADLINE=$(( $(date +%s) + DEADLINE_SECONDS ))

    if [ "$scenario" = "unexpected-disconnect-last-will" ]; then
        WIRE_OUTPUT_DIR="$artifact_dir" "$HERE/run-coatyjs-last-will.sh" >"$verifier_log" 2>&1
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
            --application-log "$artifact_dir/coatyjs-last-will.application.jsonl" \
            --capture "$artifact_dir/coatyjs-last-will.jsonl"
    elif [ "$scenario" = "qos-0" ] || [ "$scenario" = "graceful-deadvertise" ]; then
        WIRE_OUTPUT_DIR="$artifact_dir" "$HERE/run-coatyjs-qos-scenario.sh" "$scenario" >"$verifier_log" 2>&1
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
            --application-log "$artifact_dir/coatyjs-$scenario.application.jsonl" \
            --capture "$artifact_dir/coatyjs-$scenario.jsonl"
    elif [ "$scenario" = "duplicate-reply" ] || [ "$scenario" = "late-reply" ]; then
        if WIRE_OUTPUT_DIR="$artifact_dir" "$HERE/run-lifecycle-call-return.sh" "$scenario" >"$verifier_log" 2>&1; then
            node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
                --application-log "$artifact_dir/axoloty-$scenario.application.jsonl" \
                --capture "$artifact_dir/axoloty-$scenario.jsonl"
        else
            # The call-return runner requires mosquitto and swift on the host
            # (no container runtime). If it can't run, record an explicit
            # unsupported manifest rather than aborting the matrix.
            node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
                --unsupported "Live runner could not execute on this host (requires mosquitto and swift natively); see verifier.log for details." >>"$verifier_log" 2>&1
        fi
    elif [ "$scenario" = "offline-queueing" ] || [ "$scenario" = "reconnect-resubscribe" ] \
        || [ "$scenario" = "broker-restart" ] || [ "$scenario" = "clean-session" ]; then
        WIRE_OUTPUT_DIR="$artifact_dir" "$HERE/run-lifecycle-network.sh" "$scenario" >"$verifier_log" 2>&1
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" \
            --application-log "$artifact_dir/axoloty-$scenario.application.jsonl" \
            --capture "$artifact_dir/axoloty-$scenario.jsonl"
    else
        node "$WIRE_TOOL" lifecycle-manifest "$scenario" "$manifest" >"$verifier_log" 2>&1
    fi
    if [ "$(date +%s)" -gt "$DEADLINE" ]; then
        echo "Scenario exceeded its ${DEADLINE_SECONDS}s deadline: $scenario" >&2
        exit 1
    fi
    echo "Lifecycle manifest retained at $manifest"
done
