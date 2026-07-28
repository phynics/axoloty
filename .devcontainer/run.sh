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
env_file=""

cleanup() {
    if [ -n "$env_file" ]; then
        rm -f "$env_file"
    fi
    if [ "$build_lock" = "1" ]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
}

# BUILD_DIR/SPM_CACHE_DIR may be given relative to the caller's cwd (CI
# passes ".build" and ".swiftpm-cache"); container runtimes require
# absolute host paths for bind mounts, so resolve them before use.
mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd)
lock_dir="${build_dir}.lock"
trap cleanup EXIT INT TERM

if [ "$build_lock" = "1" ]; then
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 1
    done

elif [ "$build_lock" != "0" ]; then
    echo "BUILD_LOCK must be 0 or 1, got: $build_lock" >&2
    exit 2
fi

if [ "${AXOLOTY_DEVCONTAINER:-0}" = "1" ]; then
    "$@"
    exit $?
fi

if [ -z "$runtime" ]; then
    echo "No podman or docker runtime found" >&2
    exit 1
fi

mkdir -p "$spm_cache_dir"
spm_cache_dir=$(cd "$spm_cache_dir" && pwd)
mount_suffix=
case "$runtime" in
    *podman*) mount_suffix=:Z ;;
esac
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
# --privileged is only needed for rootful device access; omit it for
# regular rootless targets so CI and non-device builds are unaffected.
privileged_opt=""
if [ -n "$sudo_prefix" ]; then
    privileged_opt="--privileged"
fi

set +e
$sudo_prefix "$runtime" run --rm $security_opts $device_opts $privileged_opt $env_opts \
    -v "$root_dir:$workdir$mount_suffix" \
    -v "$build_dir:$workdir/.build$mount_suffix" \
    -v "$spm_cache_dir:$workdir/.swiftpm-cache$mount_suffix" \
    -w "$workdir" \
    "$image" "$@"
status=$?
set -e

# Rootful device runs can create root-owned logs and ESP-IDF metadata in the
# bind-mounted build and ignored test-output directories. Reclaim them even
# when the container command fails so subsequent host and rootless operations
# retain a usable feedback loop.
if [ -n "$sudo_prefix" ] && [ "${CONTAINER_RECLAIM_BUILD_DIR:-0}" = "1" ]; then
    "$sudo_prefix" "$runtime" run --rm \
        -v "$build_dir:/build$mount_suffix" \
        "$image" chown -R "$(id -u):$(id -g)" /build
    if [ -d "$root_dir/.testing" ]; then
        "$sudo_prefix" "$runtime" run --rm \
            -v "$root_dir/.testing:/testing$mount_suffix" \
            "$image" chown -R "$(id -u):$(id -g)" /testing
    fi
fi

exit "$status"
