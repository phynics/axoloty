#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

build_dir="$TEMP_DIR/build"
lock_dir="${build_dir}.lock"

# The lock must be released after a direct devcontainer command exits.
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" "$ROOT_DIR/.devcontainer/run.sh" true
[[ ! -e "$lock_dir" ]]

# A second operation waits for the owner instead of touching the shared cache.
mkdir "$lock_dir"
( sleep 1; rmdir "$lock_dir" ) &
start=$(date +%s)
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" "$ROOT_DIR/.devcontainer/run.sh" true
elapsed=$(( $(date +%s) - start ))

[[ "$elapsed" -ge 1 ]]
[[ ! -e "$lock_dir" ]]

# Isolated CI runners do not share a build directory, so they must not wait
# behind an unrelated lock directory.
mkdir "$lock_dir"
AXOLOTY_DEVCONTAINER=1 BUILD_DIR="$build_dir" BUILD_LOCK=0 "$ROOT_DIR/.devcontainer/run.sh" true
[[ -d "$lock_dir" ]]
rmdir "$lock_dir"
