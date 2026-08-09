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
socket_server=""

cleanup() {
    if [ -n "$socket_server" ]; then
        kill "$socket_server" 2>/dev/null || true
        wait "$socket_server" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

common_git_dir=$(git -C "$ROOT_DIR" rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$common_git_dir" ]; then
    expected_repository_name=$(basename "${common_git_dir%/.git}")
else
    expected_repository_name=$(basename "$ROOT_DIR")
fi

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
capture_child_env="$TEMP_DIR/runtime-child-env.txt"
mkdir -p "$fake_bin"
cat > "$fake_bin/fake-sudo" <<'SH'
#!/bin/sh
if [ "$1" = "-n" ]; then shift; fi
FAKE_RUNTIME_ROOTFUL=1 exec "$@"
SH
cat > "$fake_bin/fake-podman" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$capture"
if [ "\$1" = "system" ] && [ "\$2" = "service" ]; then
    exec python3 -c 'import socket,sys,time; p=sys.argv[1][7:]; s=socket.socket(socket.AF_UNIX); s.bind(p); s.listen(1); time.sleep(300)' "\$4"
fi
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
if [ "\${FAKE_RUNTIME_EXECUTE_COMMAND:-0}" = "1" ] && [ "\$1" = "run" ]; then
    shift
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            -e|--env)
                export "\$2"
                shift 2
                ;;
            --env-file|-v|-w|--security-opt|--user|--device|-p|--network)
                shift 2
                ;;
            --rm|--privileged|-i|--userns=*)
                shift
                ;;
            axoloty-dev)
                shift
                exec "\$@"
                ;;
            *)
                shift
                ;;
        esac
    done
    exit 2
fi
case "\$*" in
    *chown*)
        if [ "\${FAKE_RECLAIM_FAILURE:-0}" = "1" ]; then exit 42; fi
        ;;
    *)
        if [ "\${FAKE_RUNTIME_EXIT_CODE:-0}" != "0" ]; then exit "\${FAKE_RUNTIME_EXIT_CODE}"; fi
        ;;
esac
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

# Host Podman is opt-in: ordinary project commands do not receive a host
# socket, while the wire bridge reuses an already-running service and keeps
# the repository's host path as the container workdir for remote bind mounts.
: > "$capture"
CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
if grep -Eq -- 'CONTAINER_HOST|DOCKER_HOST' "$capture"; then
    echo "ordinary container run unexpectedly enabled host Podman" >&2
    exit 1
fi

host_socket="$TEMP_DIR/podman socket.sock"
python3 - "$host_socket" <<'PY' &
import socket
import sys
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
server.accept()
PY
socket_server=$!
for _ in 1 2 3 4 5; do
    [ -S "$host_socket" ] && break
    sleep 0.1
done
: > "$capture"
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
grep -q -- "-w $ROOT_DIR" "$capture"
grep -q -- "AXOLOTY_DEVCONTAINER=1" "$capture"
grep -q -- "CONTAINER_RUNTIME=$ROOT_DIR/.devcontainer/container-runtime-remote.sh" "$capture"
grep -q -- "AXOLOTY_HOST_RUNTIME_BRIDGE=1" "$capture"
grep -q -- "DOCKER_HOST=unix://$host_socket" "$capture"
grep -q -- "BUILD_DIR=$build_dir" "$capture"
grep -q -- "SPM_CACHE_DIR=$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" "$capture"
grep -q -- "REPOSITORY_NAME=$expected_repository_name" "$capture"
grep -q -- "TMPDIR=$ROOT_DIR/.testing/tmp" "$capture"
grep -Eq -- 'WIRE_RUN_ID=[0-9]+-[0-9]+' "$capture"
grep -q -- "$build_dir:$build_dir" "$capture"
grep -q -- "$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux:$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux" "$capture"
grep -q -- '--security-opt label=disable' "$capture"
[ -S "$host_socket" ]

# Execute a local observer through the fake container boundary. This verifies
# child visibility of the complete bridge contract without contacting Podman.
bridge_observer="$TEMP_DIR/observe-bridge-environment.sh"
cat > "$bridge_observer" <<'SH'
#!/bin/sh
set -eu
socket_path=${DOCKER_HOST#unix://}
[ "$AXOLOTY_DEVCONTAINER" = "1" ]
[ "$AXOLOTY_HOST_RUNTIME_BRIDGE" = "1" ]
[ -x "$CONTAINER_RUNTIME" ]
[ -S "$socket_path" ]
printf '%s\n' \
    "$AXOLOTY_DEVCONTAINER" \
    "$AXOLOTY_HOST_RUNTIME_BRIDGE" \
    "$CONTAINER_RUNTIME" \
    "$DOCKER_HOST" > "$1"
SH
chmod +x "$bridge_observer"
FAKE_RUNTIME_EXECUTE_COMMAND=1 \
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" "$bridge_observer" "$capture_child_env"
{
    IFS= read -r observed_devcontainer
    IFS= read -r observed_bridge
    IFS= read -r observed_runtime
    IFS= read -r observed_docker_host
} < "$capture_child_env"
[[ "$observed_devcontainer" = "1" ]]
[[ "$observed_bridge" = "1" ]]
[[ "$observed_runtime" = "$ROOT_DIR/.devcontainer/container-runtime-remote.sh" ]]
[[ "$observed_docker_host" = "unix://$host_socket" ]]
kill "$socket_server" 2>/dev/null || true
wait "$socket_server" 2>/dev/null || true
socket_server=""

# CI already uses worktree-local cache paths. Each destination must appear
# once rather than as both a same-path mount and a worktree-relative alias.
: > "$capture"
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$ROOT_DIR/.build" \
    SPM_CACHE_DIR="$ROOT_DIR/.swiftpm-cache" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
[[ $(grep -o -- "$ROOT_DIR/.build:$ROOT_DIR/.build" "$capture" | wc -l) -eq 1 ]]
[[ $(grep -o -- "$ROOT_DIR/.swiftpm-cache:$ROOT_DIR/.swiftpm-cache" "$capture" | wc -l) -eq 1 ]]

# When no socket exists, the bridge starts a temporary service and removes it
# after the container exits.
rm -f "$host_socket"
: > "$capture"
AXOLOTY_HOST_RUNTIME_BRIDGE=1 CONTAINER_HOST="unix://$host_socket" \
    CONTAINER_RUNTIME="$fake_bin/fake-podman" BUILD_DIR="$build_dir" BUILD_LOCK=0 \
    "$ROOT_DIR/.devcontainer/run.sh" true
[ ! -e "$host_socket" ]

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
