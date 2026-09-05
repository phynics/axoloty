#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Self-test for check-benchmark-size.sh (issue #299).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-benchmark-size.sh"
fixtures="$root/Tests/Support/fixtures/benchmark-size"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
raw_dir="$tmp/raw"
mkdir -p "$raw_dir"
cp "$fixtures"/* "$raw_dir/"
cp "$root/Package.swift" "$raw_dir/package-swift.txt"
cp "$root/Packages/AxolotyWire/Package.swift" "$raw_dir/wire-package-swift.txt"
current_json="$tmp/size-baseline.json"
sh "$checker" --parse "$raw_dir" > "$current_json"

node --input-type=module - "$current_json" <<'JS'
import fs from "node:fs";
import assert from "node:assert/strict";
const document = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const wire = document.consumers.AxolotyWireConsumer;
const host = document.consumers.AxolotyConsumer;
assert.equal(wire.unstrippedBytes, 50640);
assert.equal(wire.strippedBytes, 12000);
assert.equal(wire.sections.text, 42000);
assert.equal(wire.sections.rodata, 8000);
assert.equal(wire.sections.data, 480);
assert.equal(wire.sections.bss, 160);
assert.equal(wire.sha256, "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2");
assert.ok(wire.dynamicLibraries.includes("libswiftCore.so"));
assert.ok(!wire.dynamicLibraries.includes("libssl.so.3"));
assert.deepEqual(wire.dependencyClosure, ["AxolotyWire"]);
assert.equal(wire.hostDependencyCheck, "passed");
assert.equal(host.unstrippedBytes, 2652800);
assert.equal(host.strippedBytes, 980000);
assert.equal(host.sections.text, 2200000);
assert.ok(host.dynamicLibraries.includes("libssl.so.3"));
assert.equal(host.hostDependencyCheck, "n/a");
for (const dependency of ["Axoloty", "AxolotyWire", "mqtt-nio", "swift-nio"]) {
  assert.ok(host.dependencyClosure.includes(dependency), `missing ${dependency}`);
}
console.log("parse verification passed");
JS

baseline="$tmp/baseline.json"
cp "$current_json" "$baseline"
sh "$checker" --compare "$current_json" "$baseline" >/dev/null
node "$root/Tests/Support/benchmarks/size-test-fixtures.mjs" "$root/Package.swift" "$raw_dir/package-swift.txt" "$current_json" "$tmp/tampered.json"
if sh "$checker" --compare "$current_json" "$tmp/tampered.json" >/dev/null 2>&1; then
    echo "error: expected --compare to fail when byte count differs beyond tolerance" >&2
    exit 1
fi
if ! sh "$checker" --compare "$current_json" "$tmp/tampered.json" 2>&1 | grep -qi "unstrippedBytes"; then
    echo "error: expected unstrippedBytes in the diff output" >&2
    exit 1
fi

leaked_json="$tmp/leaked.json"
sh "$checker" --parse "$raw_dir" > "$leaked_json"
node --input-type=module - "$leaked_json" <<'JS'
import fs from "node:fs";
import assert from "node:assert/strict";
const document = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
assert.equal(document.consumers.AxolotyWireConsumer.hostDependencyCheck, "FAILED");
JS
leaked_baseline="$tmp/leaked-baseline.json"
cp "$leaked_json" "$leaked_baseline"
if sh "$checker" --compare "$leaked_json" "$leaked_baseline" >/dev/null 2>&1; then
    echo "error: expected --compare to fail when host-dep check is FAILED" >&2
    exit 1
fi
if ! sh "$checker" --compare "$leaked_json" "$leaked_baseline" 2>&1 | grep -qi "host dependencies leaked"; then
    echo "error: expected host dependency diagnostic" >&2
    exit 1
fi
echo "SELF-TEST OK"
