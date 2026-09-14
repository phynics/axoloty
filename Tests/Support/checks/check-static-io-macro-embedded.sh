#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Compatibility entry point for the Core-owned Embedded Swift consumer gate.
# The canonical checker compiles every portable module before expanding the
# real StaticIoActor fixture; it does not consume firmware build artifacts.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/check-embedded-swift-core.sh" "$@"
