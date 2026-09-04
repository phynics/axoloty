#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
manifest="$root_dir/Tests/Support/test-tiers.json"
build_path=${BUILD_DIR:-"$root_dir/.build"}
cache_path=${SPM_CACHE_DIR:-"$root_dir/.swiftpm-cache"}
list_timeout=${AXOLOTY_DISCOVERY_TIMEOUT_SECONDS:-600}
list_output=$(mktemp)
trap 'rm -f "$list_output"' EXIT

cd "$root_dir"

if ! timeout "$list_timeout" swift test \
    --list-tests \
    --scratch-path "$build_path" \
    --cache-path "$cache_path" \
    --disable-automatic-resolution \
    >"$list_output" 2>&1; then
    echo "error: SwiftPM test discovery failed; see the listing output below" >&2
    cat "$list_output" >&2
    exit 1
fi

while IFS=$'\t' read -r node_id filter; do
    if [ -z "$node_id" ] || [ -z "$filter" ]; then
        echo "error: canonical test filter record is incomplete" >&2
        exit 1
    fi

    # A manifest filter is one SwiftPM regular expression. Parenthesizing the
    # complete expression keeps each `|` alternative scoped to this filter.
    discovered_count=$(grep -E -c "($filter)" "$list_output" || true)
    if [ "$discovered_count" -eq 0 ]; then
        echo "error: $node_id filter discovered zero tests: $filter" >&2
        exit 1
    fi
    echo "PASS: $node_id discovered=$discovered_count filter=$filter"
done < <(node - "$manifest" <<'NODE'
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
for (const id of ["test-unit", "test-module", "test-wire"]) {
  const node = manifest.nodes.find(candidate => candidate.id === id);
  if (!node || typeof node.filter !== "string" || !node.filter) {
    throw new Error(`${id}: missing canonical Swift test filter`);
  }
  process.stdout.write(`${id}\t${node.filter}\n`);
}
NODE
)
