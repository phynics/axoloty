#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

lock_dir=/workspace/.swiftpm-cache/.resolve.lock
while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 1
done
trap 'rmdir "$lock_dir"' EXIT INT TERM

swift package resolve --cache-path /workspace/.swiftpm-cache
