#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Keep diagnostics from intentionally failing fixtures distinguishable from a
# real self-test failure. The command's complete output is captured before it
# is relayed, so a fixture cannot interleave an alarming raw line with the
# harness' own diagnostics.

run_labeled_command() {
    local label="$1"
    shift
    local output status
    output=$(mktemp "${TMPDIR:-/tmp}/axoloty-expected-output.XXXXXX")
    if "$@" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    RUN_LABELED_STATUS=$status
    if [ -s "$output" ]; then
        sed "s|^|[expected:${label}] |" "$output" >&2
    fi
    rm -f "$output"
    return "$status"
}

run_expected_failure() {
    local label="$1"
    local expected_status="$2"
    shift 2
    local status
    if run_labeled_command "$label" "$@"; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq 0 ]; then
        echo "expected failure did not fail: ${label}" >&2
        return 1
    fi
    RUN_EXPECTED_FAILURE_STATUS=$status
    if [ "$expected_status" != "any" ] && [ "$status" -ne "$expected_status" ]; then
        echo "expected failure returned ${status}, wanted ${expected_status}: ${label}" >&2
        return 1
    fi
    return 0
}
