#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# A provisional budget manifest is useful for development, but it is not
# host/device release evidence. The hardware checkpoint must name an external
# evidence document and validate it against this exact clean commit.

set -eu
root=${AXOLOTY_G6_RESOURCE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
evidence=${AXOLOTY_G6_RESOURCE_EVIDENCE:-}
[ -n "$evidence" ] || { echo "G6 RESOURCE EVIDENCE FAIL: AXOLOTY_G6_RESOURCE_EVIDENCE is required" >&2; exit 1; }
[ -f "$evidence" ] || { echo "G6 RESOURCE EVIDENCE FAIL: evidence file is missing: $evidence" >&2; exit 1; }
evidenceRoot=$(CDPATH= cd -- "$(dirname -- "$evidence")" && pwd)
node "$root/Tests/Support/validate-g6-resource-evidence.mjs" "$evidence" "$evidenceRoot" "$root"
