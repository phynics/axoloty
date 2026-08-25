#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Shared bounded process helpers for the macOS-only legacy wire runners.
# These helpers use only POSIX shell, ps, kill, and sleep so Linux self-tests
# can exercise the cleanup contract without the legacy toolchain.

legacy_monotonic_ms() {
    timestamp=$(date +%s%3N 2>/dev/null || true)
    case "$timestamp" in
        ''|*[^0-9]*) timestamp=$(( $(date +%s) * 1000 )) ;;
    esac
    printf '%s\n' "$timestamp"
}

legacy_process_live() {
    legacy_pid="$1"
    legacy_state=$(ps -o stat= -p "$legacy_pid" 2>/dev/null | tr -d ' ' || true)
    case "$legacy_state" in
        ''|Z*) return 1 ;;
        *) return 0 ;;
    esac
}

legacy_wait_for_exit() {
    legacy_pid="$1"
    legacy_timeout="$2"
    legacy_label="$3"
    legacy_wait_for_exit_until "$legacy_pid" "$(( $(legacy_monotonic_ms) + legacy_timeout * 1000 ))" "$legacy_label" "$legacy_timeout"
}

legacy_wait_for_exit_until() {
    legacy_pid="$1"
    legacy_deadline="$2"
    legacy_label="$3"
    legacy_timeout="${4:-deadline}"

    while legacy_process_live "$legacy_pid"; do
        if [ "$(legacy_monotonic_ms)" -ge "$legacy_deadline" ]; then
            echo "legacy timeout: label=$legacy_label pid=$legacy_pid elapsed=${legacy_timeout}s" >&2
            if legacy_terminate_and_reap "$legacy_pid" "$legacy_label timeout"; then
                return 124
            fi
            return 125
        fi
        sleep 0.1
    done

    wait "$legacy_pid" 2>/dev/null
}

legacy_terminate_and_reap() {
    legacy_pid="$1"
    legacy_label="$2"
    if legacy_process_live "$legacy_pid"; then
        echo "legacy cleanup: label=$legacy_label pid=$legacy_pid signal=TERM" >&2
        kill -TERM "$legacy_pid" 2>/dev/null || true
        legacy_deadline=$(( $(legacy_monotonic_ms) + LEGACY_TERM_GRACE_SECONDS * 1000 ))
        while legacy_process_live "$legacy_pid" && [ "$(legacy_monotonic_ms)" -lt "$legacy_deadline" ]; do
            sleep 0.1
        done
    fi

    if legacy_process_live "$legacy_pid"; then
        echo "legacy cleanup: label=$legacy_label pid=$legacy_pid signal=KILL" >&2
        kill -KILL "$legacy_pid" 2>/dev/null || true
        legacy_deadline=$(( $(legacy_monotonic_ms) + LEGACY_KILL_GRACE_SECONDS * 1000 ))
        while legacy_process_live "$legacy_pid" && [ "$(legacy_monotonic_ms)" -lt "$legacy_deadline" ]; do
            sleep 0.1
        done
    fi

    if legacy_process_live "$legacy_pid"; then
        echo "legacy cleanup failure: label=$legacy_label pid=$legacy_pid phase=reap-timeout" >&2
        return 125
    fi
    wait "$legacy_pid" 2>/dev/null || true
    return 0
}

legacy_cleanup_pid() {
    legacy_pid="$1"
    [ -n "$legacy_pid" ] || return 0
    legacy_terminate_and_reap "$legacy_pid" "exit cleanup" || true
}
