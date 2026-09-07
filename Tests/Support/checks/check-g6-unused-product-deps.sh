#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# A directly-declared SwiftPM product dependency that no source in its
# target imports is structurally invisible to docs/module-policy.yml (which
# only checks import statements against its own allowed-list, never
# Package.swift). It costs a resolution/link-graph entry for nothing, and
# has silently reached this repository before (root Axoloty target's
# IkigaJSON dependency, and Tests/AxolotyTests's, both since removed).

set -eu

root=${AXOLOTY_G6_UNUSED_PRODUCT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)}
validator="$root/Tests/Support/evidence/validate-g6-unused-product-deps.mjs"
[ -f "$validator" ] || { echo "G6 UNUSED PRODUCT DEPS FAIL: validator missing" >&2; exit 1; }

report=$(node "$validator" "$root") || {
    printf '%s\n' "$report" >&2
    exit 1
}
printf '%s\n' "$report"
