#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

cache_dir=${AXOLOTY_RESOLVE_CACHE_DIR:-/workspace/.swiftpm-cache}
lock_file="$cache_dir/.resolve.flock"
legacy_lock_dir="$cache_dir/.resolve.lock"
legacy_marker="$legacy_lock_dir/.flock-v2"
legacy_stale_seconds=${AXOLOTY_RESOLVE_LEGACY_STALE_SECONDS:-3600}
package_path=${AXOLOTY_RESOLVE_PACKAGE_PATH:-.}

mkdir -p "$cache_dir"
command -v flock >/dev/null 2>&1 || {
    echo "error: flock is required for SwiftPM resolution locking" >&2
    exit 69
}

exec 9>"$lock_file"
flock 9

# Older runners used an ownerless mkdir lock that survived SIGKILL. Preserve
# mutual exclusion with those runners while recovering v2 or hour-old locks.
while [ -d "$legacy_lock_dir" ]; do
    if [ -d "$legacy_marker" ]; then
        rmdir "$legacy_marker" "$legacy_lock_dir" 2>/dev/null || {
            echo "error: stale SwiftPM resolve lock is not empty: $legacy_lock_dir" >&2
            exit 1
        }
        break
    fi
    modified=$(stat -c %Y "$legacy_lock_dir" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ $(( now - modified )) -ge "$legacy_stale_seconds" ]; then
        rmdir "$legacy_lock_dir" 2>/dev/null || {
            echo "error: stale SwiftPM resolve lock is not empty: $legacy_lock_dir" >&2
            exit 1
        }
        break
    fi
    sleep 1
done

mkdir "$legacy_lock_dir"
mkdir "$legacy_marker"
trap 'rmdir "$legacy_marker" "$legacy_lock_dir"' EXIT INT TERM

if [ "$package_path" = . ]; then
    swift package resolve --cache-path "$cache_dir"
else
    swift package --package-path "$package_path" resolve --cache-path "$cache_dir"
fi
