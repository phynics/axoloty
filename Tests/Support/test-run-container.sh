#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

# Each scenario below sets BUILD_LOCK explicitly (or relies on run.sh's
# default of 1); an inherited BUILD_LOCK from the caller's environment (e.g.
# `make ci ... BUILD_LOCK=0`, which the Makefile exports) would silently
# override that and break the lock-behavior assertions.
unset BUILD_LOCK

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

build_dir="$TEMP_DIR/build"
lock_file="${build_dir}.lock"
lock_owner="${build_dir}.lock.owner"

# The lock must be released after a direct devcontainer command exits.
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" "$ROOT_DIR/.devcontainer/run.sh" true
[[ ! -e "$lock_owner" ]]

# A second operation waits for the owner instead of touching the shared cache.
( exec 8>"$lock_file"; flock 8; sleep 1 ) &
holder=$!
sleep 0.1
start=$(date +%s)
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" "$ROOT_DIR/.devcontainer/run.sh" true
elapsed=$(( $(date +%s) - start ))

[[ "$elapsed" -ge 1 ]]
wait "$holder"
[[ ! -e "$lock_owner" ]]

# The mkdir fallback cannot wait forever when flock is unavailable.
fallback_lock_dir="${build_dir}.lock.d"
mkdir "$fallback_lock_dir"
if BUILD_LOCK_FORCE_DIRECTORY=1 BUILD_LOCK_TIMEOUT=0 AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected the fallback lock timeout to fail" >&2
    exit 1
fi
rmdir "$fallback_lock_dir"

# Isolated CI runners do not share a build directory, so they must not wait
# behind an unrelated lock directory.
( exec 8>"$lock_file"; flock 8; sleep 2 ) &
holder=$!
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" BUILD_LOCK=0 "$ROOT_DIR/.devcontainer/run.sh" true
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# Device runs auto-select a usable non-interactive sudo wrapper. Use fakes so
# the behavior is deterministic and does not require a real device or sudo.
fake_bin="$TEMP_DIR/bin"
capture="$TEMP_DIR/runtime-args.txt"
capture_env="$TEMP_DIR/runtime-env.txt"
mkdir -p "$fake_bin"
cat > "$fake_bin/fake-sudo" <<'SH'
#!/bin/sh
if [ "$1" = "-n" ]; then shift; fi
FAKE_RUNTIME_ROOTFUL=1 exec "$@"
SH
cat > "$fake_bin/fake-podman" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$capture"
if [ "\$1" = "image" ] && [ "\$2" = "inspect" ]; then
    if [ "\${FAKE_RUNTIME_ROOTFUL:-0}" = "1" ]; then
        printf '%s\n' "\${FAKE_RUNTIME_ROOTFUL_IMAGE_ID:-rootful-image}"
    else
        printf '%s\n' rootless-image
    fi
    exit 0
fi
if [ "\$1" = "save" ]; then
    printf '%s' fake-image
    exit 0
fi
if [ "\$1" = "load" ]; then
    cat >/dev/null
    exit 0
fi
if [[ "\${FAKE_RECLAIM_FAILURE:-0}" == "1" && "\$*" == *chown* ]]; then
    exit 42
fi
if [[ "\${FAKE_RUNTIME_EXIT_CODE:-0}" != "0" && "\$*" != *chown* ]]; then
    exit "\${FAKE_RUNTIME_EXIT_CODE}"
fi
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "--env-file" ]; then
        cp "\$2" "$capture_env"
        break
    fi
    shift
done
SH
chmod +x "$fake_bin/fake-sudo" "$fake_bin/fake-podman"
device="$TEMP_DIR/device"
: > "$device"
SUDO_CANDIDATES="$fake_bin/fake-sudo" \
CONTAINER_DEVICES="$device" CONTAINER_RUNTIME="$fake_bin/fake-podman" \
CONTAINER_ENV_VARS="EMBEDDED_SKIP_BUILD EMBEDDED_BUILD_DIR" \
EMBEDDED_SKIP_BUILD=1 EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift \
CONTAINER_RECLAIM_BUILD_DIR=1 BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '--privileged' "$capture"
grep -q -- "--device $device" "$capture"
if grep -q -- '--user ' "$capture"; then
    echo "device run unexpectedly set an ordinary user" >&2
    exit 1
fi
grep -q -- '--env-file ' "$capture"
grep -qx -- 'EMBEDDED_SKIP_BUILD=1' "$capture_env"
grep -qx -- 'EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift' "$capture_env"
grep -q -- 'chown -R ' "$capture"
grep -q -- 'save axoloty-dev' "$capture"
grep -q -- 'load' "$capture"
save_line=$(grep -n -- 'save axoloty-dev' "$capture" | cut -d: -f1)
run_line=$(grep -n -m1 -- 'run --rm' "$capture" | cut -d: -f1)
[[ "$save_line" -lt "$run_line" ]]

# Matching rootless and rootful image IDs do not transfer the image again.
: > "$capture"
FAKE_RUNTIME_ROOTFUL_IMAGE_ID=rootless-image \
SUDO_CANDIDATES="$fake_bin/fake-sudo" \
CONTAINER_DEVICES="$device" CONTAINER_RUNTIME="$fake_bin/fake-podman" \
BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
if grep -q -- 'save axoloty-dev\|load' "$capture"; then
    echo "matching rootful image was transferred again" >&2
    exit 1
fi

# Optional devices are forwarded when present and ignored when absent.
: > "$capture"
CONTAINER_OPTIONAL_DEVICES="$device $TEMP_DIR/absent-device" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- "--user $(id -u):$(id -g)" "$capture"
grep -q -- '--env HOME=/tmp' "$capture"

# Reclaim failures are warnings and must not replace the container command's status.
: > "$capture"
set +e
FAKE_RECLAIM_FAILURE=1 FAKE_RUNTIME_EXIT_CODE=7 \
SUDO_CANDIDATES="$fake_bin/fake-sudo" CONTAINER_DEVICES="$device" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" CONTAINER_RECLAIM_BUILD_DIR=1 \
BUILD_DIR="$build_dir" BUILD_LOCK=0 "$ROOT_DIR/.devcontainer/run.sh" true
reclaim_status=$?
set -e
[[ "$reclaim_status" -eq 7 ]]
grep -q -- "--device $device" "$capture"
if grep -q -- "$TEMP_DIR/absent-device" "$capture"; then
    echo "absent optional device was forwarded" >&2
    exit 1
fi
if grep -q -- 'save axoloty-dev\|load' "$capture"; then
    echo "rootless optional-device run synchronized an image" >&2
    exit 1
fi

if CONTAINER_RUNTIME="$fake_bin/fake-podman" CONTAINER_ENV_VARS=1 \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected an invalid container environment name to fail" >&2
    exit 1
fi

# --- CONTAINER_PORTS tests ---

# Single port mapping produces -p flag.
: > "$capture"
CONTAINER_PORTS="127.0.0.1:1883:1883" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '-p 127.0.0.1:1883:1883' "$capture"

# Multiple port mappings each produce -p flags.
: > "$capture"
CONTAINER_PORTS="127.0.0.1:1883:1883 127.0.0.1:8765:8765" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '-p 127.0.0.1:1883:1883' "$capture"
grep -q -- '-p 127.0.0.1:8765:8765' "$capture"

# No port flags when CONTAINER_PORTS is not set.
: > "$capture"
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
if grep -q -- '-p ' "$capture"; then
    echo "unexpected -p flag in ordinary command" >&2
    exit 1
fi

# Invalid port spec with shell metacharacter is rejected.
if CONTAINER_PORTS="127.0.0.1:1883:1883;echo pwned" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected shell-metacharacter port spec to fail" >&2
    exit 1
fi

# Newline in port spec is rejected.
if CONTAINER_PORTS="127.0.0.1:1883:1883
8765" \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected newline port spec to fail" >&2
    exit 1
fi

# --- CONTAINER_NETWORK tests ---

# Host networking produces the expected runtime flag.
: > "$capture"
CONTAINER_NETWORK=host \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '--network host' "$capture"

# Arbitrary runtime flags are rejected.
if CONTAINER_NETWORK='host --privileged' \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected invalid container network to fail" >&2
    exit 1
fi

# --- CONTAINER_STDIN tests ---

# CONTAINER_STDIN=1 produces -i.
: > "$capture"
CONTAINER_STDIN=1 \
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '-i' "$capture"

# CONTAINER_STDIN=1 never produces -t.
if grep -qw -- '-t' "$capture"; then
    echo "unexpected -t flag with CONTAINER_STDIN=1" >&2
    exit 1
fi

# No -i flag when CONTAINER_STDIN is not set.
: > "$capture"
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
run_args=$(cat "$capture")
if echo "$run_args" | grep -qw -- '-i'; then
    echo "unexpected -i flag in ordinary command" >&2
    exit 1
fi
