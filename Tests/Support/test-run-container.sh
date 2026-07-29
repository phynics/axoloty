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
exec "$@"
SH
cat > "$fake_bin/fake-runtime" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$capture"
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "--env-file" ]; then
        cp "\$2" "$capture_env"
        break
    fi
    shift
done
SH
chmod +x "$fake_bin/fake-sudo" "$fake_bin/fake-runtime"
device="$TEMP_DIR/device"
: > "$device"
SUDO_CANDIDATES="$fake_bin/fake-sudo" \
CONTAINER_DEVICES="$device" CONTAINER_RUNTIME="$fake_bin/fake-runtime" \
CONTAINER_ENV_VARS="EMBEDDED_SKIP_BUILD EMBEDDED_BUILD_DIR" \
EMBEDDED_SKIP_BUILD=1 EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift \
CONTAINER_RECLAIM_BUILD_DIR=1 BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- '--privileged' "$capture"
grep -q -- "--device $device" "$capture"
grep -q -- '--env-file ' "$capture"
grep -qx -- 'EMBEDDED_SKIP_BUILD=1' "$capture_env"
grep -qx -- 'EMBEDDED_BUILD_DIR=/workspace/.build/embedded-swift' "$capture_env"
grep -q -- 'chown -R ' "$capture"

# Optional devices are forwarded when present and ignored when absent.
: > "$capture"
CONTAINER_OPTIONAL_DEVICES="$device $TEMP_DIR/absent-device" \
CONTAINER_RUNTIME="$fake_bin/fake-runtime" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- "--device $device" "$capture"
if grep -q -- "$TEMP_DIR/absent-device" "$capture"; then
    echo "absent optional device was forwarded" >&2
    exit 1
fi

if CONTAINER_RUNTIME="$fake_bin/fake-runtime" CONTAINER_ENV_VARS=1 \
    BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true 2>/dev/null; then
    echo "expected an invalid container environment name to fail" >&2
    exit 1
fi
