#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-$(command -v podman || command -v docker)}
IMAGE=${IMAGE:-axoloty-dev}
BUILD_DIR=${BUILD_DIR:-"$root/.testing/observed-objects/build"}
export CONTAINER_RUNTIME IMAGE BUILD_DIR

make --no-print-directory image

CONTAINER_COMMAND_TIMEOUT_SECONDS=${CONTAINER_COMMAND_TIMEOUT_SECONDS:-1800} \
    exec .devcontainer/run.sh swift test \
        --package-path /workspace/Spikes/ObservedObjects \
        --scratch-path /workspace/.build \
        --cache-path /workspace/.swiftpm-cache \
        --disable-automatic-resolution -Xswiftc -warnings-as-errors "$@"
