# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Shared by the live wire-compatibility scripts. Source it after `RUNTIME` is
# set; do not execute it.
#
# `podman wait` and `docker wait` print the container's exit status and exit 0
# whatever that status is, so `if ! runtime wait "$c"; then` never sees a failed
# Swift test. wait_for_success reads the printed status instead.

# wait_for_success CONTAINER
#
# Waits up to WIRE_CONTAINER_WAIT_SECONDS (default 120) for CONTAINER to exit
# and succeeds only when it exits with status 0. On every failure it reports the
# reason and the container log on stderr, then returns:
#   124  the wait timed out (the container is also stopped and killed)
#   1    the wait command failed, printed no numeric status, or the status was
#        nonzero
wait_for_success() {
    local container="$1" status="" wait_rc=0
    status=$(timeout "${WIRE_CONTAINER_WAIT_SECONDS:-120}s" "$RUNTIME" wait "$container") || wait_rc=$?
    status=${status//[[:space:]]/}
    if [ "$wait_rc" -eq 124 ]; then
        echo "Container $container did not exit within ${WIRE_CONTAINER_WAIT_SECONDS:-120}s" >&2
        "$RUNTIME" logs "$container" >&2 || true
        "$RUNTIME" stop -t 1 "$container" >/dev/null 2>&1 || true
        "$RUNTIME" kill "$container" >/dev/null 2>&1 || true
        return 124
    fi
    if [ "$wait_rc" -ne 0 ]; then
        echo "Waiting for container $container failed with status $wait_rc" >&2
    elif [[ ! "$status" =~ ^[0-9]+$ ]]; then
        echo "Container $container reported a non-numeric exit status: '${status:-empty}'" >&2
    elif [ "$status" != "0" ]; then
        echo "Container $container exited with status $status" >&2
    else
        return 0
    fi
    "$RUNTIME" logs "$container" >&2 || true
    return 1
}
