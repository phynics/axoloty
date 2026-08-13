#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${CONTAINER_RUNTIME:-}
image=${IMAGE:-axoloty-dev}
workdir=${WORKDIR:-/workspace}
build_dir=${BUILD_DIR:-"$root_dir/.build"}
spm_cache_dir=${SPM_CACHE_DIR:-"${HOME}/.cache/coaty-swift/swiftpm/swift-6.3-linux"}
build_lock=${BUILD_LOCK:-1}
lock_timeout=${BUILD_LOCK_TIMEOUT:-300}
lock_stale_after=${BUILD_LOCK_STALE_SECONDS:-3600}
env_file=""
runtime_output_file=""
lock_kind=""
lock_owner=""
host_service_pid=""
host_service_socket=""
host_service_dir=""
bridge_socket=""
container_name=""
container_state_dir=""
container_cidfile=""
container_id=""
container_run_id=""
container_owner_id=""
container_instance_id=""
container_pid=""
direct_pid=""
active_runtime_api_pid=""
container_launching=0
container_created=0
container_started=0
cleanup_failure=0
container_term_grace="${CONTAINER_TERM_GRACE_SECONDS:-5}"
container_kill_grace="${CONTAINER_KILL_GRACE_SECONDS:-2}"
runtime_api_timeout="${CONTAINER_API_TIMEOUT_SECONDS:-5}"
container_create_timeout="${CONTAINER_CREATE_TIMEOUT_SECONDS:-120}"
sudo_prefix=""
session_prefix=""
session_wait=""

process_tree_alive() {
    pid="$1"
    if process_is_alive "$pid"; then
        return 0
    fi
    if kill -0 -- "-$pid" 2>/dev/null; then
        group_states=$(ps -o stat= -g "$pid" 2>/dev/null || true)
        for group_state in $group_states; do
            case "$group_state" in
                Z*) ;;
                *) return 0 ;;
            esac
        done
    fi
    return 1
}

process_is_alive() {
    pid="$1"
    kill -0 "$pid" 2>/dev/null || return 1
    process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    case "$process_state" in
        ''|Z*) return 1 ;;
    esac
    return 0
}

wait_for_process_tree() {
    pid="$1"
    grace="$2"
    deadline=$(( $(date +%s) + grace ))
    while process_tree_alive "$pid"; do
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            return 1
        fi
        sleep 0.1
    done
    return 0
}

reap_process_if_stopped() {
    pid="$1"
    if process_tree_alive "$pid"; then
        return 1
    fi
    # wait is reached only after the process group has disappeared, so it is
    # an immediate reap rather than an unbounded cleanup wait.
    if wait "$pid" 2>/dev/null; then
        return 0
    else
        return $?
    fi
}

wait_for_process_completion() {
    pid="$1"
    if wait "$pid"; then
        status=0
    else
        status=$?
    fi
    if process_tree_alive "$pid"; then
        if ! terminate_process_tree_bounded "$pid" "completed process descendants"; then
            return 125
        fi
    fi
    return "$status"
}

terminate_process_tree_bounded() {
    pid="$1"
    label="$2"
    if ! process_tree_alive "$pid"; then
        reap_process_if_stopped "$pid" || true
        return 0
    fi

    kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    if wait_for_process_tree "$pid" "$container_term_grace"; then
        reap_process_if_stopped "$pid" || true
        return 0
    fi

    kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    if wait_for_process_tree "$pid" "$container_kill_grace"; then
        reap_process_if_stopped "$pid" || true
        return 0
    fi

    cleanup_failure=1
    echo "cleanup failure: $label process tree pid=$pid remained alive after SIGKILL deadline; detaching" >&2
    return 1
}

run_command_bounded() {
    command_output="$1"
    command_label="$2"
    command_timeout="$3"
    shift 3
    if [ -n "$session_prefix" ]; then
        $session_prefix $session_wait "$@" >"$command_output" 2>&1 &
    else
        "$@" >"$command_output" 2>&1 &
    fi
    command_pid=$!
    active_runtime_api_pid="$command_pid"
    command_deadline=$(( $(date +%s) + command_timeout ))
    while process_is_alive "$command_pid"; do
        if [ "$(date +%s)" -ge "$command_deadline" ]; then
            terminate_process_tree_bounded "$command_pid" "$command_label" || true
            active_runtime_api_pid=""
            return 124
        fi
        sleep 0.1
    done
    if wait "$command_pid"; then
        command_status=0
    else
        command_status=$?
    fi
    if process_tree_alive "$command_pid"; then
        if ! terminate_process_tree_bounded "$command_pid" "$command_label descendants"; then
            active_runtime_api_pid=""
            return 125
        fi
    fi
    active_runtime_api_pid=""
    return "$command_status"
}

container_has_expected_labels() {
    ownership_target="$container_id"
    if [ -z "$ownership_target" ]; then
        return 2
    fi
    if ! run_command_bounded "$runtime_output_file" "container ownership inspection" "$runtime_api_timeout" \
        $sudo_prefix "$runtime" inspect \
        --format '{{.Id}}|{{ index .Config.Labels "io.axoloty.managed-by" }}|{{ index .Config.Labels "io.axoloty.run-id" }}|{{ index .Config.Labels "io.axoloty.worktree" }}|{{ index .Config.Labels "io.axoloty.owner" }}|{{ index .Config.Labels "io.axoloty.instance" }}' \
        "$ownership_target"; then
        return 2
    fi
    ownership_record=$(cat "$runtime_output_file")
    discovered_id=${ownership_record%%|*}
    owned_labels=${ownership_record#*|}
    case "$discovered_id" in
        ''|*[!A-Za-z0-9_.:-]*) return 2 ;;
    esac
    [ "$discovered_id" = "$container_id" ] || return 2
    [ "$owned_labels" = "axoloty-run.sh|$container_run_id|$worktree_name|$container_owner_id|$container_instance_id" ]
}

reconcile_created_container() {
    if ! run_command_bounded "$runtime_output_file" "created-container reconciliation" "$runtime_api_timeout" \
        $sudo_prefix "$runtime" inspect \
        --format '{{.Id}}|{{ index .Config.Labels "io.axoloty.managed-by" }}|{{ index .Config.Labels "io.axoloty.run-id" }}|{{ index .Config.Labels "io.axoloty.worktree" }}|{{ index .Config.Labels "io.axoloty.owner" }}|{{ index .Config.Labels "io.axoloty.instance" }}' \
        "$container_name"; then
        return 1
    fi
    ownership_record=$(cat "$runtime_output_file")
    discovered_id=${ownership_record%%|*}
    owned_labels=${ownership_record#*|}
    case "$discovered_id" in
        ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
    esac
    if [ "$owned_labels" != "axoloty-run.sh|$container_run_id|$worktree_name|$container_owner_id|$container_instance_id" ]; then
        return 1
    fi
    container_id="$discovered_id"
    return 0
}

recover_created_container() {
    if [ -s "$container_cidfile" ]; then
        recovered_id=$(tr -d '\r\n' < "$container_cidfile")
        case "$recovered_id" in
            ''|*[!A-Za-z0-9_.:-]*) ;;
            *)
                container_id="$recovered_id"
                container_created=1
                return 0
                ;;
        esac
    fi
    for _ in 1 2 3; do
        if reconcile_created_container; then
            container_created=1
            return 0
        fi
        sleep 0.1
    done
    return 1
}

container_presence() {
    runtime_basename=$(basename "$runtime")
    case "$runtime_basename" in
        *podman*)
            if run_command_bounded /dev/null "container existence inspection" "$runtime_api_timeout" \
                $sudo_prefix "$runtime" container exists "$container_id"; then
                return 0
            else
                presence_status=$?
            fi
            [ "$presence_status" -eq 1 ] && return 1
            return 2
            ;;
        *docker*)
            if run_command_bounded "$runtime_output_file" "container existence inspection" "$runtime_api_timeout" \
                $sudo_prefix "$runtime" inspect "$container_id"; then
                return 0
            else
                presence_status=$?
            fi
            case "$presence_status" in
                124|125) return 2 ;;
            esac
            if grep -Eiq 'no such (container|object)' "$runtime_output_file"; then
                return 1
            fi
            return 2
            ;;
        *)
            if run_command_bounded /dev/null "container existence inspection" "$runtime_api_timeout" \
                $sudo_prefix "$runtime" inspect "$container_id"; then
                return 0
            fi
            return 2
            ;;
    esac
}

cleanup_container() {
    if [ "$container_launching" -ne 1 ]; then
        return
    fi
    if [ "$container_created" -ne 1 ]; then
        recover_created_container || return 0
    fi
    if [ -z "$container_id" ]; then
        return
    fi
    if [ -n "$container_pid" ]; then
        terminate_process_tree_bounded "$container_pid" "runtime client" || true
        container_pid=""
    fi
    if container_has_expected_labels; then
        :
    else
        ownership_status=$?
        if [ "$ownership_status" -eq 2 ]; then
            cleanup_failure=1
            echo "cleanup warning: ownership inspection failed for $container_id; leaving it untouched" >&2
        else
            echo "cleanup warning: ownership labels changed for $container_name; leaving it untouched" >&2
        fi
        return
    fi
    container_state=""
    if run_command_bounded "$runtime_output_file" "container state inspection" "$runtime_api_timeout" \
        $sudo_prefix "$runtime" inspect --format '{{.State.Status}}' "$container_id"; then
        container_state=$(cat "$runtime_output_file")
    fi
    if [ "$container_state" = "running" ]; then
        stop_status=0
        run_command_bounded /dev/null "container stop" "$runtime_api_timeout" \
            $sudo_prefix "$runtime" stop --time "$container_term_grace" "$container_id" || stop_status=$?
        container_state=""
        if run_command_bounded "$runtime_output_file" "container state inspection" "$runtime_api_timeout" \
            $sudo_prefix "$runtime" inspect --format '{{.State.Status}}' "$container_id"; then
            container_state=$(cat "$runtime_output_file")
        elif [ "$stop_status" -ne 0 ]; then
            cleanup_failure=1
            echo "cleanup warning: failed to stop owned container $container_id within the bounded deadline" >&2
        fi
        if [ "$container_state" = "running" ]; then
            if ! run_command_bounded /dev/null "container kill" "$runtime_api_timeout" \
                $sudo_prefix "$runtime" kill "$container_id"; then
                cleanup_failure=1
                echo "cleanup warning: failed to kill owned container $container_id within the bounded deadline" >&2
            fi
        fi
    fi
    if container_has_expected_labels; then
        :
    else
        ownership_status=$?
        if [ "$ownership_status" -eq 2 ]; then
            cleanup_failure=1
            echo "cleanup warning: ownership inspection failed before removal of $container_id; leaving it untouched" >&2
        else
            if container_presence; then
                cleanup_failure=1
                echo "cleanup warning: ownership labels changed before removal of $container_id; leaving it untouched" >&2
            else
                presence_status=$?
                if [ "$presence_status" -eq 2 ]; then
                    cleanup_failure=1
                    echo "cleanup warning: container presence was inconclusive for $container_id; leaving it untouched" >&2
                fi
            fi
        fi
        return
    fi
    removed=0
    for _ in 1 2; do
        if run_command_bounded /dev/null "container removal" "$runtime_api_timeout" \
            $sudo_prefix "$runtime" rm -f "$container_id"; then
            removed=1
            break
        fi
    done
    if [ "$removed" -ne 1 ]; then
        if container_presence; then
            cleanup_failure=1
            echo "cleanup failure: owned container $container_id could not be removed" >&2
            return
        else
            presence_status=$?
        fi
        if [ "$presence_status" -eq 2 ]; then
            cleanup_failure=1
            echo "cleanup failure: could not determine whether owned container $container_id was removed" >&2
            return
        fi
    fi
    container_started=0
    container_launching=0
}

cleanup() {
    cleanup_status=$?
    cleanup_container
    if [ -n "$env_file" ]; then
        rm -f "$env_file"
    fi
    if [ -n "$runtime_output_file" ]; then
        rm -f "$runtime_output_file"
    fi
    if [ -n "$container_cidfile" ]; then
        rm -f "$container_cidfile"
    fi
    if [ -n "$container_state_dir" ]; then
        rmdir "$container_state_dir" 2>/dev/null || true
    fi
    if [ -n "$lock_owner" ]; then
        rm -f "$lock_owner"
    fi
    if [ -n "$host_service_pid" ]; then
        kill "$host_service_pid" 2>/dev/null || true
        terminate_process_tree_bounded "$host_service_pid" "host runtime service" || true
        host_service_pid=""
    fi
    if [ -n "$host_service_socket" ]; then
        rm -f "$host_service_socket"
    fi
    if [ -n "$host_service_dir" ]; then
        rmdir "$host_service_dir" 2>/dev/null || true
    fi
    if [ "$lock_kind" = "directory" ]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    if [ "$cleanup_failure" -ne 0 ] && [ "$cleanup_status" -eq 0 ]; then
        cleanup_status=125
    fi
    exit "$cleanup_status"
}

forward_signal() {
    signal="$1"
    if [ -n "$active_runtime_api_pid" ]; then
        terminate_process_tree_bounded "$active_runtime_api_pid" "runtime API operation" || true
        active_runtime_api_pid=""
        if [ "$container_launching" -eq 1 ] && [ "$container_created" -ne 1 ]; then
            recover_created_container || true
        fi
    fi
    target_pid="${container_pid:-$direct_pid}"
    if [ -n "$target_pid" ]; then
        if [ "$target_pid" = "$container_pid" ]; then
            # Keep the runtime client alive until EXIT cleanup has had a
            # bounded chance to observe delayed ownership labels. cleanup_container
            # performs the TERM/KILL escalation and bounded reap.
            kill -"$signal" -- "-$target_pid" 2>/dev/null || kill -"$signal" "$target_pid" 2>/dev/null || true
        else
            terminate_process_tree_bounded "$target_pid" "forwarded command" || true
            direct_pid=""
        fi
    fi
    case "$signal" in
        INT) exit 130 ;;
        TERM) exit 143 ;;
        *) exit 128 ;;
    esac
}

# BUILD_DIR/SPM_CACHE_DIR may be given relative to the caller's cwd (CI
# passes ".build" and ".swiftpm-cache"); container runtimes require
# absolute host paths for bind mounts, so resolve them before use.
mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd)
lock_file="${build_dir}.lock"
lock_dir="${build_dir}.lock.d"
lock_owner_file="${build_dir}.lock.owner"
trap cleanup EXIT
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

case "$lock_stale_after" in
    ''|*[!0-9]*)
        echo "BUILD_LOCK_STALE_SECONDS must be a non-negative integer" >&2
        exit 2
        ;;
esac
case "$container_term_grace" in
    ''|*[!0-9]*)
        echo "CONTAINER_TERM_GRACE_SECONDS must be a non-negative integer" >&2
        exit 2
        ;;
esac
case "$container_kill_grace" in
    ''|*[!0-9]*)
        echo "CONTAINER_KILL_GRACE_SECONDS must be a non-negative integer" >&2
        exit 2
        ;;
esac
case "$runtime_api_timeout" in
    ''|*[!0-9]*)
        echo "CONTAINER_API_TIMEOUT_SECONDS must be a non-negative integer" >&2
        exit 2
        ;;
esac
case "$container_create_timeout" in
    ''|*[!0-9]*)
        echo "CONTAINER_CREATE_TIMEOUT_SECONDS must be a non-negative integer" >&2
        exit 2
        ;;
esac
if [ "$container_term_grace" -gt 300 ] || [ "$container_kill_grace" -gt 300 ]; then
    echo "container termination grace periods must be <= 300 seconds" >&2
    exit 2
fi
if [ "$runtime_api_timeout" -gt 120 ]; then
    echo "CONTAINER_API_TIMEOUT_SECONDS must be <= 120 seconds" >&2
    exit 2
fi
if [ "$container_create_timeout" -gt 300 ]; then
    echo "CONTAINER_CREATE_TIMEOUT_SECONDS must be <= 300 seconds" >&2
    exit 2
fi

if command -v setsid >/dev/null 2>&1; then
    session_prefix=$(command -v setsid)
    session_wait="-w"
fi

lock_is_stale() {
    [ -d "$lock_dir" ] || return 1
    lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null || true)
    case "$lock_mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    lock_now=$(date +%s)
    [ "$lock_now" -ge "$lock_mtime" ] || return 1
    [ "$((lock_now - lock_mtime))" -ge "$lock_stale_after" ] || return 1

    lock_owner_pid_value=""
    if [ -f "$lock_owner_file" ]; then
        while IFS='=' read -r lock_key lock_value; do
            if [ "$lock_key" = "pid" ]; then
                lock_owner_pid_value="$lock_value"
            fi
        done < "$lock_owner_file"
    fi
    case "$lock_owner_pid_value" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$lock_owner_pid_value" 2>/dev/null; then
                return 1
            fi
            ;;
    esac
    return 0
}

if [ "$build_lock" = "1" ]; then
    if [ "${BUILD_LOCK_FORCE_DIRECTORY:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
        exec 9>"$lock_file"
        if [ "$lock_timeout" -ge 0 ]; then
            if ! flock -w "$lock_timeout" 9; then
                echo "Timed out waiting for build lock: $lock_file" >&2
                exit 75
            fi
        else
            flock 9
        fi
        lock_kind="flock"
    else
        lock_started=$(date +%s)
        while ! mkdir "$lock_dir" 2>/dev/null; do
            if lock_is_stale; then
                echo "Removing stale build lock: $lock_dir" >&2
                rm -f "$lock_owner_file"
                rmdir "$lock_dir" 2>/dev/null || true
                continue
            fi
            if [ "$lock_timeout" -ge 0 ] && [ "$(( $(date +%s) - lock_started ))" -ge "$lock_timeout" ]; then
                echo "Timed out waiting for build lock: $lock_dir" >&2
                exit 75
            fi
            sleep 1
        done
        lock_kind="directory"
    fi
    if [ "$lock_kind" = "directory" ]; then
        lock_owner=$lock_owner_file
        printf 'pid=%s\nworkdir=%s\n' "$$" "$root_dir" > "$lock_owner"
    fi

elif [ "$build_lock" != "0" ]; then
    echo "BUILD_LOCK must be 0 or 1, got: $build_lock" >&2
    exit 2
fi

if [ "${AXOLOTY_DEVCONTAINER:-0}" = "1" ]; then
    set +e
    status=0
    if [ -n "$session_prefix" ]; then
        $session_prefix $session_wait "$@" &
    else
        "$@" &
    fi
    direct_pid=$!
    wait_for_process_completion "$direct_pid" || status=$?
    status=${status:-0}
    direct_pid=""
    set -e
    exit "$status"
fi

if [ -z "$runtime" ]; then
    echo "No podman or docker runtime found" >&2
    exit 1
fi

common_git_dir=$(git -C "$root_dir" rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$common_git_dir" ]; then
    repository_name=$(basename "${common_git_dir%/.git}")
else
    repository_name=$(basename "$root_dir")
fi
worktree_name=${WORKTREE_NAME:-$(basename "$root_dir")}
worktree_name=$(printf '%s' "$worktree_name" | tr -c 'A-Za-z0-9_.-' '-')
worktree_name=$(printf '%s' "$worktree_name" | cut -c1-24)
if [ -z "$worktree_name" ]; then
    worktree_name=worktree
fi
worktree_hash=$(printf '%s' "$root_dir" | cksum | cut -d ' ' -f1)
if [ -z "$worktree_hash" ]; then
    echo "Unable to construct a worktree identity" >&2
    exit 2
fi
container_run_id=${AXOLOTY_RUN_ID:-${WIRE_RUN_ID:-"$$-$(date +%s)"}}
container_run_id=$(printf '%s' "$container_run_id" | tr -c 'A-Za-z0-9_.-' '-')
container_owner_id=${AXOLOTY_OWNER_ID:-$$}
container_owner_id=$(printf '%s' "$container_owner_id" | tr -c 'A-Za-z0-9_.-' '-')
if [ -z "$container_owner_id" ]; then
    echo "Unable to construct a container owner identity" >&2
    exit 2
fi
container_run_token=$(printf '%s' "$container_run_id" | cut -c1-24)
container_name=${CONTAINER_NAME:-"axoloty-${worktree_hash}-${container_run_token}-${container_owner_id}"}
container_name=$(printf '%s' "$container_name" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-63)
if [ -z "$container_name" ]; then
    echo "Unable to construct an owned container name" >&2
    exit 2
fi
export AXOLOTY_RUN_ID="$container_run_id"
runtime_output_file=$(mktemp "${TMPDIR:-/tmp}/axoloty-runtime-output.XXXXXX")
container_state_dir=$(mktemp -d "${TMPDIR:-/tmp}/axoloty-container-state.XXXXXX")
container_cidfile="$container_state_dir/container.id"
container_instance_id=$(basename "$container_state_dir")

bridge_workdir="$workdir"
if [ "${AXOLOTY_HOST_RUNTIME_BRIDGE:-0}" = "1" ]; then
    case "$runtime" in
        *podman*) ;;
        *) echo "AXOLOTY_HOST_RUNTIME_BRIDGE requires a Podman host runtime" >&2; exit 2 ;;
    esac
    bridge_workdir="$root_dir"
    existing_socket=${CONTAINER_HOST:-}
    existing_socket=${existing_socket#unix://}
    if [ -z "${CONTAINER_HOST:-}" ]; then
        existing_socket="/run/user/$(id -u)/podman/podman.sock"
    fi
    if [ -S "$existing_socket" ]; then
        bridge_socket="$existing_socket"
    else
        host_service_dir=$(mktemp -d "${TMPDIR:-/tmp}/axoloty-podman.XXXXXX")
        host_service_socket="$host_service_dir/podman.sock"
        "$runtime" system service --time=0 "unix://$host_service_socket" >/dev/null 2>&1 &
        host_service_pid=$!
        ready=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if [ -S "$host_service_socket" ]; then ready=1; break; fi
            sleep 1
        done
        if [ "$ready" -ne 1 ]; then
            echo "Timed out waiting for host Podman service" >&2
            exit 1
        fi
        bridge_socket="$host_service_socket"
    fi
    bridge_runtime="$root_dir/.devcontainer/container-runtime-remote.sh"
    if [ ! -x "$bridge_runtime" ]; then
        echo "Host-runtime bridge wrapper is not executable: $bridge_runtime" >&2
        exit 1
    fi
    if [ ! -S "$bridge_socket" ]; then
        echo "Host-runtime bridge socket is unavailable: $bridge_socket" >&2
        exit 1
    fi
    bridge_tmpdir="$root_dir/.testing/tmp"
    bridge_run_id=${WIRE_RUN_ID:-$container_run_id}
    mkdir -p "$bridge_tmpdir"
    repository_name=${REPOSITORY_NAME:-$repository_name}
fi

mkdir -p "$spm_cache_dir"
spm_cache_dir=$(cd "$spm_cache_dir" && pwd)
mount_suffix=
selinux_labeling_active=0
if [ "${CONTAINER_MOUNT_SUFFIX+x}" = x ]; then
    # Callers on unusual hosts can explicitly request :Z/:z, or set an empty
    # value to disable relabeling even when the host's SELinux state is hidden.
    mount_suffix=${CONTAINER_MOUNT_SUFFIX}
    case "$mount_suffix" in
        '') ;;
        :Z|:z) selinux_labeling_active=1 ;;
        *) echo "CONTAINER_MOUNT_SUFFIX must be empty, :Z, or :z" >&2; exit 2 ;;
    esac
elif [ -r /sys/fs/selinux/enforce ] && [ "$(cat /sys/fs/selinux/enforce)" = 1 ]; then
    mount_suffix=:Z
    selinux_labeling_active=1
fi
device_lease_mount=""
device_lease_env=""
device_lease_root=""
if [ -n "${AXOLOTY_DEVICE_LEASE_ROOT:-}" ]; then
    mkdir -p "$AXOLOTY_DEVICE_LEASE_ROOT"
    device_lease_root=$(cd "$AXOLOTY_DEVICE_LEASE_ROOT" && pwd)
    device_lease_mount_suffix=""
    if [ "$selinux_labeling_active" -eq 1 ]; then
        device_lease_mount_suffix=:z
    fi
    device_lease_mount="$device_lease_root:$device_lease_root$device_lease_mount_suffix"
    device_lease_env="AXOLOTY_DEVICE_LEASE_ROOT=$device_lease_root"
fi
# Extra `podman run`/`docker run` flags for targets that need a relaxed
# sandbox. Used by `make test-tsan`: ThreadSanitizer must disable ASLR via
# the `personality` syscall, which the default seccomp profile denies. Empty
# by default so other targets are unaffected.
security_opts=${CONTAINER_SECURITY_OPTS:-}
# Explicit allow-list of host environment variable names to forward. Setting
# variables on the run.sh invocation does not otherwise pass them through the
# container runtime boundary.
container_env_vars=${CONTAINER_ENV_VARS:-}
env_opts=""
if [ -n "$container_env_vars" ]; then
    umask 077
    env_file=$(mktemp "${TMPDIR:-/tmp}/axoloty-container-env.XXXXXX")
    for env_name in $container_env_vars; do
        case "$env_name" in
            ""|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
                echo "Invalid CONTAINER_ENV_VARS entry: $env_name" >&2
                exit 2
                ;;
        esac
        eval "env_value=\${$env_name-}"
        case "$env_value" in
            *'
'*)
                echo "Container environment value contains a newline: $env_name" >&2
                exit 2
                ;;
        esac
        printf '%s=%s\n' "$env_name" "$env_value" >> "$env_file"
    done
    env_opts="--env-file $env_file"
fi
# Optional USB device passthrough for embedded targets. Empty by default so
# non-embedded targets are unaffected. Set CONTAINER_DEVICES to a
# space-separated list of device paths (e.g. "/dev/ttyACM0") to forward them
# into the container.
container_devices=${CONTAINER_DEVICES:-}
optional_container_devices=${CONTAINER_OPTIONAL_DEVICES:-}
if [ -n "$optional_container_devices" ]; then
    for dev in $optional_container_devices; do
        if [ -e "$dev" ]; then
            container_devices="$container_devices $dev"
        fi
    done
fi
device_opts=""
if [ -n "$container_devices" ]; then
    for dev in $container_devices; do
        device_opts="$device_opts --device $dev"
    done
fi
# Optional sudo prefix for targets that need rootful container access
# (e.g. device benchmarks that need --privileged + /dev/ttyACM0). Empty
# by default so non-device targets are unaffected. Set SUDO to "sudo" or
# a path like "/run/wrappers/bin/sudo" to enable rootful container runs.
sudo_prefix=${SUDO-}
if [ -z "$sudo_prefix" ] && [ -n "$container_devices" ]; then
    sudo_candidates=${SUDO_CANDIDATES:-"/run/wrappers/bin/sudo sudo"}
    for candidate in $sudo_candidates; do
        case "$candidate" in
            */*) resolved_sudo=$candidate ;;
            *) resolved_sudo=$(command -v "$candidate" 2>/dev/null || true) ;;
        esac
        if [ -n "${resolved_sudo:-}" ] && [ -x "$resolved_sudo" ] \
                && "$resolved_sudo" -n "$runtime" info >/dev/null 2>&1; then
            sudo_prefix=$resolved_sudo
            echo "Using rootful container runtime via $sudo_prefix" >&2
            break
        fi
    done
fi

if [ -n "$container_devices" ] && [ -z "$sudo_prefix" ]; then
    for dev in $container_devices; do
        if [ ! -r "$dev" ] || [ ! -w "$dev" ]; then
            echo "Device $dev is not accessible and no non-interactive sudo wrapper was found" >&2
            echo "Set SUDO explicitly or install /run/wrappers/bin/sudo (NixOS)" >&2
            exit 1
        fi
    done
fi

# Rootless and rootful Podman use separate image stores. A device run needs
# rootful Podman for /dev access, so synchronize the freshly built local image
# when its image ID differs from the rootful copy. Docker has one image store
# and does not need this handoff.
if [ -n "$container_devices" ] && [ -n "$sudo_prefix" ]; then
    case "$runtime" in
        *podman*)
            local_image_id=$($runtime image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)
            rootful_image_id=$($sudo_prefix "$runtime" image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)
            if [ -z "$local_image_id" ]; then
                echo "Local image $image is unavailable for rootful device synchronization" >&2
                exit 1
            fi
            if [ "$local_image_id" != "$rootful_image_id" ]; then
                echo "Synchronizing $image into rootful Podman storage" >&2
                $runtime save "$image" | $sudo_prefix "$runtime" load
            fi
            ;;
    esac
fi

# --privileged is only needed for rootful device access; omit it for
# regular rootless targets so CI and non-device builds are unaffected.
privileged_opt=""
user_opt=""
userns_opt=""
home_opt=""
if [ -n "$sudo_prefix" ]; then
    privileged_opt="--privileged"
else
    user_opt="--user $(id -u):$(id -g)"
    home_opt="--env HOME=/tmp"
    case "$runtime" in
        *podman*) userns_opt="--userns=keep-id" ;;
    esac
fi

# Optional port forwarding for serve commands. Empty by default so
# ordinary build and test commands are unaffected. Set CONTAINER_PORTS to
# a space-separated list of port mappings (e.g. "127.0.0.1:1883:1883").
container_ports=${CONTAINER_PORTS:-}
port_opts=""
if [ -n "$container_ports" ]; then
    # Reject control characters (newlines, tabs) before word splitting
    # would silently turn them into spec separators.
    case "$container_ports" in
        *[![:print:]]*)
            echo "Invalid CONTAINER_PORTS: control characters are not allowed" >&2
            exit 2
            ;;
    esac
    for port_spec in $container_ports; do
        case "$port_spec" in
            ""|*[!0-9A-Za-z.:-]*)
                echo "Invalid CONTAINER_PORTS entry: $port_spec" >&2
                exit 2
                ;;
        esac
        port_opts="$port_opts -p $port_spec"
    done
fi

# Local services bind to loopback, so the wrappers use host networking to
# expose them without weakening their listen-host policy. Do not accept
# arbitrary runtime flags through the environment.
network_opt=""
case "${CONTAINER_NETWORK:-}" in
    "") ;;
    host) network_opt="--network host" ;;
    *)
        echo "Invalid CONTAINER_NETWORK: only host is supported" >&2
        exit 2
        ;;
esac

# Optional stdin forwarding for MCP stdio mode. Adds -i but never -t.
# Allocating a TTY could corrupt or buffer protocol traffic.
stdin_opt=""
if [ "${CONTAINER_STDIN:-0}" = "1" ]; then
    stdin_opt="-i"
fi

set +e
container_launching=1
create_container() {
    if [ "${AXOLOTY_HOST_RUNTIME_BRIDGE:-0}" = "1" ]; then
        # Keep bridge paths as discrete arguments. Disabling SELinux separation
        # for this opt-in container avoids relabeling a live rootless Podman
        # socket.
        if [ -n "$device_lease_mount" ]; then
            run_command_bounded "$runtime_output_file" "container create" "$container_create_timeout" \
                $sudo_prefix "$runtime" create \
                $security_opts $device_opts $privileged_opt $userns_opt $user_opt $home_opt $env_opts $port_opts $stdin_opt $network_opt \
                --security-opt label=disable \
                -e AXOLOTY_DEVCONTAINER=1 \
                -e AXOLOTY_HOST_RUNTIME_BRIDGE=1 \
                -e "CONTAINER_RUNTIME=$bridge_runtime" \
                -e "DOCKER_HOST=unix://$bridge_socket" \
                -e "WORKDIR=$root_dir" \
                -e "BUILD_DIR=$build_dir" \
                -e "SPM_CACHE_DIR=$spm_cache_dir" \
                -e "REPOSITORY_NAME=$repository_name" \
                -e "TMPDIR=$bridge_tmpdir" \
                -e "WIRE_RUN_ID=$bridge_run_id" \
                -e "AXOLOTY_RUN_ID=$container_run_id" \
                -v "$bridge_socket:$bridge_socket" \
                -v "$build_dir:$build_dir" \
                -v "$spm_cache_dir:$spm_cache_dir" \
                -v "$device_lease_mount" \
                -e "$device_lease_env" \
                -v "$root_dir:$bridge_workdir$mount_suffix" \
                -w "$bridge_workdir" \
                --name "$container_name" \
                --cidfile "$container_cidfile" \
                --label io.axoloty.managed-by=axoloty-run.sh \
                --label "io.axoloty.run-id=$container_run_id" \
                --label "io.axoloty.worktree=$worktree_name" \
                --label "io.axoloty.owner=$container_owner_id" \
                --label "io.axoloty.instance=$container_instance_id" \
                "$image" "$@"
        else
            run_command_bounded "$runtime_output_file" "container create" "$container_create_timeout" \
                $sudo_prefix "$runtime" create \
                $security_opts $device_opts $privileged_opt $userns_opt $user_opt $home_opt $env_opts $port_opts $stdin_opt $network_opt \
                --security-opt label=disable \
                -e AXOLOTY_DEVCONTAINER=1 \
                -e AXOLOTY_HOST_RUNTIME_BRIDGE=1 \
                -e "CONTAINER_RUNTIME=$bridge_runtime" \
                -e "DOCKER_HOST=unix://$bridge_socket" \
                -e "WORKDIR=$root_dir" \
                -e "BUILD_DIR=$build_dir" \
                -e "SPM_CACHE_DIR=$spm_cache_dir" \
                -e "REPOSITORY_NAME=$repository_name" \
                -e "TMPDIR=$bridge_tmpdir" \
                -e "WIRE_RUN_ID=$bridge_run_id" \
                -e "AXOLOTY_RUN_ID=$container_run_id" \
                -v "$bridge_socket:$bridge_socket" \
                -v "$build_dir:$build_dir" \
                -v "$spm_cache_dir:$spm_cache_dir" \
                -v "$root_dir:$bridge_workdir$mount_suffix" \
                -w "$bridge_workdir" \
                --name "$container_name" \
                --cidfile "$container_cidfile" \
                --label io.axoloty.managed-by=axoloty-run.sh \
                --label "io.axoloty.run-id=$container_run_id" \
                --label "io.axoloty.worktree=$worktree_name" \
                --label "io.axoloty.owner=$container_owner_id" \
                --label "io.axoloty.instance=$container_instance_id" \
                "$image" "$@"
        fi
    elif [ -n "$device_lease_mount" ]; then
        run_command_bounded "$runtime_output_file" "container create" "$container_create_timeout" \
            $sudo_prefix "$runtime" create \
            $security_opts $device_opts $privileged_opt $userns_opt $user_opt $home_opt $env_opts $port_opts $stdin_opt $network_opt \
            -e AXOLOTY_DEVCONTAINER=1 \
            -e "AXOLOTY_RUN_ID=$container_run_id" \
            -v "$device_lease_mount" \
            -e "$device_lease_env" \
            -v "$root_dir:$bridge_workdir$mount_suffix" \
            -v "$build_dir:$bridge_workdir/.build$mount_suffix" \
            -v "$spm_cache_dir:$bridge_workdir/.swiftpm-cache$mount_suffix" \
            -w "$bridge_workdir" \
            --name "$container_name" \
            --cidfile "$container_cidfile" \
            --label io.axoloty.managed-by=axoloty-run.sh \
            --label "io.axoloty.run-id=$container_run_id" \
            --label "io.axoloty.worktree=$worktree_name" \
            --label "io.axoloty.owner=$container_owner_id" \
            --label "io.axoloty.instance=$container_instance_id" \
            "$image" "$@"
    else
        run_command_bounded "$runtime_output_file" "container create" "$container_create_timeout" \
            $sudo_prefix "$runtime" create \
            $security_opts $device_opts $privileged_opt $userns_opt $user_opt $home_opt $env_opts $port_opts $stdin_opt $network_opt \
            -e AXOLOTY_DEVCONTAINER=1 \
            -e "AXOLOTY_RUN_ID=$container_run_id" \
            -v "$root_dir:$bridge_workdir$mount_suffix" \
            -v "$build_dir:$bridge_workdir/.build$mount_suffix" \
            -v "$spm_cache_dir:$bridge_workdir/.swiftpm-cache$mount_suffix" \
            -w "$bridge_workdir" \
            --name "$container_name" \
            --cidfile "$container_cidfile" \
            --label io.axoloty.managed-by=axoloty-run.sh \
            --label "io.axoloty.run-id=$container_run_id" \
            --label "io.axoloty.worktree=$worktree_name" \
            --label "io.axoloty.owner=$container_owner_id" \
            --label "io.axoloty.instance=$container_instance_id" \
            "$image" "$@"
    fi
}

create_status=0
create_container "$@" || create_status=$?

# Prefer the runtime's immutable CID file. If a runtime omits it, or a bounded
# create returns after committing the object, recover only the uniquely named
# container carrying this invocation's complete ownership label set.
recover_created_container || true

if [ "$create_status" -ne 0 ]; then
    if [ "$create_status" -eq 124 ]; then
        echo "container create exceeded its ${container_create_timeout}-second deadline" >&2
    elif [ -s "$runtime_output_file" ]; then
        cat "$runtime_output_file" >&2
    fi
    status=$create_status
elif [ "$container_created" -ne 1 ]; then
    echo "container create did not yield a verifiable immutable container ID" >&2
    status=125
elif ! container_has_expected_labels; then
    echo "container ownership labels were not verified before start" >&2
    status=125
else
    start_interactive=""
    if [ "${CONTAINER_STDIN:-0}" = "1" ]; then
        start_interactive="--interactive"
    fi
    if [ -n "$session_prefix" ]; then
        $session_prefix $session_wait $sudo_prefix "$runtime" start --attach $start_interactive "$container_id" &
    else
        $sudo_prefix "$runtime" start --attach $start_interactive "$container_id" &
    fi
    container_pid=$!
    container_started=1
    status=0
    wait_for_process_completion "$container_pid" || status=$?
    status=${status:-0}
fi
container_pid=""
set -e

# Rootful device runs can create root-owned logs and ESP-IDF metadata in the
# bind-mounted build and ignored test-output directories. Reclaim them even
# when the container command fails so subsequent host and rootless operations
# retain a usable feedback loop.
if [ -n "$sudo_prefix" ] && [ "${CONTAINER_RECLAIM_BUILD_DIR:-0}" = "1" ]; then
    reclaim_status=0
    "$sudo_prefix" "$runtime" run --rm \
        -v "$build_dir:/build$mount_suffix" \
        "$image" chown -R "$(id -u):$(id -g)" /build || reclaim_status=$?
    if [ -d "$root_dir/.testing" ]; then
        "$sudo_prefix" "$runtime" run --rm \
            -v "$root_dir/.testing:/testing$mount_suffix" \
            "$image" chown -R "$(id -u):$(id -g)" /testing || reclaim_status=$?
    fi
    if [ "$reclaim_status" -ne 0 ]; then
        echo "warning: failed to reclaim root-owned container artifacts" >&2
    fi
fi

exit "$status"
