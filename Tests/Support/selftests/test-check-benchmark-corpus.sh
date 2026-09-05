#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for check-benchmark-corpus.sh (issue #298).
#
# 1. Runs the checker against the real corpus; it must succeed.
# 2. Copies the corpus to a temp dir, appends a byte to one payload; the
#    checker must fail with a SHA-256 mismatch.
# 3. Copies the corpus to a temp dir, mutates one manifest entry's family; the
#    checker must fail.
# 4. Cleans up. Prints SELF-TEST OK on success.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-benchmark-corpus.sh"
corpus="$root/Benchmarks/Corpus"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. The real corpus must validate.
if ! sh "$checker" "$corpus" >/dev/null 2>&1; then
    echo "expected checker to pass against the real corpus" >&2
    exit 1
fi

# 2. A modified payload (extra byte) must fail with a SHA mismatch.
cp -R "$corpus" "$tmp/corpus-sha"
sha_file="$tmp/corpus-sha/payloads/advertise-small.json"
printf 'X' >>"$sha_file"
if sh "$checker" "$tmp/corpus-sha" >/dev/null 2>&1; then
    echo "expected checker to fail when a payload byte is appended" >&2
    exit 1
fi
# Confirm the failure message names a SHA-256 mismatch.
if ! sh "$checker" "$tmp/corpus-sha" 2>&1 | grep -qi "SHA-256 mismatch"; then
    echo "expected SHA-256 mismatch error in checker output" >&2
    exit 1
fi

# 3. A mutated manifest family must fail.
cp -R "$corpus" "$tmp/corpus-family"
manifest="$tmp/corpus-family/manifest.json"
node --input-type=module - "$manifest" <<'JS'
import fs from "node:fs";
const path=process.argv[2], m=JSON.parse(fs.readFileSync(path)); const item=m.cases.find(c=>c.id==="advertise-small"); item.family="XXX"; item.familyName="nope"; fs.writeFileSync(path,JSON.stringify(m,null,2)+"\n");
JS
if sh "$checker" "$tmp/corpus-family" >/dev/null 2>&1; then
    echo "expected checker to fail when a manifest family is mutated" >&2
    exit 1
fi

echo "SELF-TEST OK"
