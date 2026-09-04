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
for (const id of ["test-unit", "test-module", "test-fuzz", "test-wire"]) {
  const node = manifest.nodes.find(candidate => candidate.id === id);
  if (!node || typeof node.filter !== "string" || !node.filter) {
    throw new Error(`${id}: missing canonical Swift test filter`);
  }
  process.stdout.write(`${id}\t${node.filter}\n`);
}
NODE
)

# Every discovered test must be claimed by some canonical filter.
#
# The check above proves each filter still matches at least one test, which
# catches a stale filter but never a missing one: a test added to an existing
# suite simply never ran, and every gate stayed green while it happened. That
# is not hypothetical -- 27 runtime tests and the whole of three IO suites were
# absent from the manifest and had never executed in CI.
unclaimed=$(node - "$manifest" "$list_output" <<'NODE'
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const listing = fs.readFileSync(process.argv[3], "utf8")
  .split("\n")
  .map(line => line.trim())
  .filter(line => line.includes("/") && !line.startsWith("["));
const filters = manifest.nodes
  .filter(node => typeof node.filter === "string" && node.filter)
  .map(node => new RegExp(`(${node.filter})`));
// Live wire subjects are gated behind WIRE_* environment variables and are
// driven by the lifecycle shell runners rather than by a tier filter, so they
// are deliberately unclaimed here.
const exempt = /^AxolotyLiveWireTests\./;
const unclaimed = listing.filter(test => !exempt.test(test) && !filters.some(rx => rx.test(test)));
process.stdout.write(unclaimed.join("\n"));
NODE
)

if [ -n "$unclaimed" ]; then
    echo "error: these tests are claimed by no canonical tier filter and would never run:" >&2
    printf '%s\n' "$unclaimed" >&2
    echo "hint: add the owning suite to a node filter in Tests/Support/test-tiers.json" >&2
    exit 1
fi
echo "PASS: every discovered test is claimed by a canonical tier filter"
