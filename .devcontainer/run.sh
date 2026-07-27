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

# BUILD_DIR/SPM_CACHE_DIR may be given relative to the caller's cwd (CI
# passes ".build" and ".swiftpm-cache"); container runtimes require
# absolute host paths for bind mounts, so resolve them before use.
mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd)
lock_dir="${build_dir}.lock"

if [ "$build_lock" = "1" ]; then
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 1
    done

    cleanup() {
        rmdir "$lock_dir" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM
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
sudo_prefix=${SUDO:-}
# --privileged is only needed for rootful device access; omit it for
# regular rootless targets so CI and non-device builds are unaffected.
privileged_opt=""
if [ -n "$sudo_prefix" ]; then
    privileged_opt="--privileged"
fi
$sudo_prefix "$runtime" run --rm $security_opts $device_opts $privileged_opt \
    -v "$root_dir:$workdir$mount_suffix" \
    -v "$build_dir:$workdir/.build$mount_suffix" \
    -v "$spm_cache_dir:$workdir/.swiftpm-cache$mount_suffix" \
    -w "$workdir" \
    "$image" "$@"
