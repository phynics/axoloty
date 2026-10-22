#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
mode=${1:-check}
baseline="$root/docs/api/core-1.0-public-symbols.json"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$mode" in
    check|update) ;;
    *) echo "usage: generate-core-api-baseline.sh [check|update]" >&2; exit 2 ;;
esac

swift package dump-symbol-graph \
    --minimum-access-level public \
    --skip-inherited-docs

python3 "$root/Tests/Support/checks/normalize-core-api-baseline.py" "$root/.build/out/symbolgraph" "$work/baseline.json"

if [ "$mode" = update ]; then
    cp "$work/baseline.json" "$baseline"
    printf 'Updated %s\n' "${baseline#"$root/"}"
    exit 0
fi

if [ ! -f "$baseline" ]; then
    echo "Missing API baseline: $baseline" >&2
    echo "Run make api-baseline API_BASELINE_MODE=update to create it." >&2
    exit 1
fi

if ! cmp -s "$baseline" "$work/baseline.json"; then
    diff -u "$baseline" "$work/baseline.json" || true
    echo "Core public API baseline changed; review the API and regenerate deliberately." >&2
    exit 1
fi

printf 'Core public API baseline matches %s\n' "${baseline#"$root/"}"
