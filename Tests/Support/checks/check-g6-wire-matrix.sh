#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
matrix="$root/Tests/Support/WireCompatibility/g6-scenario-matrix.json"
evidence=${AXOLOTY_G6_WIRE_EVIDENCE:-}
[ -f "$matrix" ] || { echo "G6 WIRE MATRIX FAIL: matrix manifest is missing" >&2; exit 1; }
[ -n "$evidence" ] || { echo "G6 WIRE MATRIX FAIL: AXOLOTY_G6_WIRE_EVIDENCE is required" >&2; exit 1; }
[ -f "$evidence" ] || { echo "G6 WIRE MATRIX FAIL: evidence file is missing: $evidence" >&2; exit 1; }
evidenceRoot=$(CDPATH= cd -- "$(dirname -- "$evidence")" && pwd)
node "$root/Tests/Support/evidence/validate-g6-wire-matrix.mjs" "$matrix" "$evidence" "$evidenceRoot" "$root" >/dev/null
printf '%s\n' '{"schemaVersion":1,"status":"passed","matrix":"g6-core-io-v1"}'
