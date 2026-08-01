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
lock_kind=""
lock_owner=""

cleanup() {
    if [ -n "$env_file" ]; then
        rm -f "$env_file"
    fi
    if [ -n "$lock_owner" ]; then
        rm -f "$lock_owner"
    fi
    if [ "$lock_kind" = "directory" ]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
}

# BUILD_DIR/SPM_CACHE_DIR may be given relative to the caller's cwd (CI
# passes ".build" and ".swiftpm-cache"); container runtimes require
# absolute host paths for bind mounts, so resolve them before use.
mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd)
lock_file="${build_dir}.lock"
lock_dir="${build_dir}.lock.d"
lock_owner_file="${build_dir}.lock.owner"
trap cleanup EXIT INT TERM

if [ "$build_lock" = "1" ]; then
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lock_file"
        flock 9
        lock_kind="flock"
    else
        while ! mkdir "$lock_dir" 2>/dev/null; do
            sleep 1
        done
        lock_kind="directory"
    fi
    lock_owner=$lock_owner_file
    printf 'pid=%s\nworkdir=%s\n' "$$" "$root_dir" > "$lock_owner"

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
if [ -n "$sudo_prefix" ]; then
    privileged_opt="--privileged"
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

# Optional stdin forwarding for MCP stdio mode. Adds -i but never -t.
# Allocating a TTY could corrupt or buffer protocol traffic.
stdin_opt=""
if [ "${CONTAINER_STDIN:-0}" = "1" ]; then
    stdin_opt="-i"
fi

set +e
$sudo_prefix "$runtime" run --rm $security_opts $device_opts $privileged_opt $env_opts $port_opts $stdin_opt \
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
