#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
manifest="$root_dir/Tests/Support/test-tiers.json"
build_path=${BUILD_DIR:-"$root_dir/.build"}
cache_path=${SPM_CACHE_DIR:-"$root_dir/.swiftpm-cache"}
list_timeout=${AXOLOTY_DISCOVERY_TIMEOUT_SECONDS:-600}

cd "$root_dir"

# SwiftPM's discovery is package-scoped. Run it for each filtered canonical
# node rather than checking every filter against the root package's unrelated
# test list. The Node side emits one row per alternation branch, so a branch
# that silently decays cannot hide behind a sibling branch that still matches.
# Use a non-whitespace delimiter: root-package records have an empty scratch path.
# Discovery output depends only on the package and scratch path, so each
# listing is produced once and reused by every branch that targets it; the
# manifest expands to hundreds of branches across a handful of packages.
listing_dir=$(mktemp -d)
trap 'rm -rf "$listing_dir"' EXIT
while IFS=$'\x1f' read -r node_id package_path scratch_path branch; do
    [ -n "$node_id" ] && [ -n "$branch" ] || {
        echo "error: canonical test filter record is incomplete" >&2
        exit 1
    }
    listing_key=$(printf '%s\x1f%s' "$package_path" "$scratch_path" | cksum | tr ' ' '-')
    output="$listing_dir/$listing_key.txt"
    if [ ! -f "$output" ]; then
        args=(test --list-tests --cache-path "$cache_path" --disable-automatic-resolution)
        if [ "$package_path" != "." ]; then args+=(--package-path "$package_path"); fi
        if [ -n "$scratch_path" ]; then args+=(--scratch-path "$scratch_path"); fi
        if ! timeout "$list_timeout" swift "${args[@]}" >"$output" 2>&1; then
            echo "error: SwiftPM test discovery failed for $node_id; see the listing output below" >&2
            cat "$output" >&2
            exit 1
        fi
    fi
    if ! node - "$output" "$branch" <<'NODE'
const fs = require("node:fs");
const [listingPath, branch] = process.argv.slice(2);
const lines = fs.readFileSync(listingPath, "utf8").split(/\r?\n/);
let expression;
try { expression = new RegExp(branch); }
catch (error) { console.error(`invalid filter branch ${JSON.stringify(branch)}: ${error.message}`); process.exit(2); }
if (!lines.some(line => expression.test(line))) {
  console.error(`filter discovered zero tests: ${branch}`);
  process.exit(1);
}
NODE
    then
        echo "error: $node_id filter branch discovered zero tests: $branch" >&2
        exit 1
    fi
    echo "PASS: $node_id branch=$branch"
done < <(node --input-type=module - "$manifest" <<'NODE'
import fs from "node:fs";
import { expandFilterAlternatives } from "./Tests/Support/validate-test-tiers.mjs";
const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
for (const node of manifest.nodes) {
  if (typeof node.filter !== "string" || !node.filter) continue;
  if (node.command?.executable !== "swift" || !node.command.arguments?.includes("test")) continue;
  const args = node.command.arguments;
  const packageIndex = args.indexOf("--package-path");
  const scratchIndex = args.indexOf("--scratch-path");
  const packagePath = packageIndex >= 0 ? args[packageIndex + 1] : ".";
  const scratchPath = scratchIndex >= 0 ? args[scratchIndex + 1] : "";
  for (const branch of expandFilterAlternatives(node.filter)) {
    process.stdout.write([node.id, packagePath, scratchPath, branch].join("\x1f") + "\n");
  }
}
NODE
)
