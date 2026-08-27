#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
matrix="$root/Tests/Support/WireCompatibility/g6-scenario-matrix.json"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$matrix" "$tmp/matrix.json"
node "$root/Tests/Support/validate-g6-wire-matrix.mjs" "$tmp/matrix.json" "" "$root" >/dev/null
node -e 'const fs=require("fs"); const p=process.argv[1]; const d=JSON.parse(fs.readFileSync(p)); d.requiredCells.push(d.requiredCells[0]); fs.writeFileSync(p, JSON.stringify(d));' "$tmp/matrix.json"
if node "$root/Tests/Support/validate-g6-wire-matrix.mjs" "$tmp/matrix.json" "" "$root" >/dev/null 2>&1; then
    echo "error: matrix validator accepted a duplicate required cell" >&2
    exit 1
fi
echo "G6 wire matrix negative self-test passed"
