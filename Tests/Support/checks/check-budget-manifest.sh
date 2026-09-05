#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
manifest=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)/Benchmarks/Baselines/budget-manifest.json}
[ -f "$manifest" ] || { echo "BUDGET MANIFEST FAIL: manifest not found at $manifest" >&2; exit 1; }
node "$(dirname "$0")/../benchmarks/budget-manifest.mjs" "$manifest" || { echo "BUDGET MANIFEST FAIL: validation failed (see errors above)" >&2; exit 1; }
