#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Self-test for the wire benchmark orchestration (issue #300).
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$root"

known_fingerprint="93eea5f6ced99549956392d934fb21310328cd4c14491f7fe44c451c8098d6ee"
oracle_fingerprint=$(node "$root/Tests/Support/corpus-fingerprint.mjs" "$root/Benchmarks/Corpus")
[ "$oracle_fingerprint" = "$known_fingerprint" ] || {
    echo "Node corpus oracle does not match known digest" >&2
    exit 1
}

build_dir=${BUILD_DIR:-$root/.build}
mkdir -p "$build_dir"
container_runtime=${CONTAINER_RUNTIME:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)}
[ -n "$container_runtime" ] || { echo "No podman or docker runtime found" >&2; exit 1; }
CONTAINER_RUNTIME="$container_runtime" \
IMAGE="${IMAGE:-axoloty-dev}" \
BUILD_DIR="$build_dir" \
    "$root/.devcontainer/run.sh" swift build -c release \
        --cache-path /workspace/.swiftpm-cache \
        --disable-automatic-resolution \
        --product WireBenchmark

swift_fingerprint_one=$(CONTAINER_RUNTIME="$container_runtime" \
    IMAGE="${IMAGE:-axoloty-dev}" BUILD_DIR="$build_dir" \
    "$root/.devcontainer/run.sh" /workspace/.build/release/WireBenchmark --corpus-fingerprint)
swift_fingerprint_two=$(CONTAINER_RUNTIME="$container_runtime" \
    IMAGE="${IMAGE:-axoloty-dev}" BUILD_DIR="$build_dir" \
    "$root/.devcontainer/run.sh" /workspace/.build/release/WireBenchmark --corpus-fingerprint)
[ "$swift_fingerprint_one" = "$oracle_fingerprint" ] || {
    echo "WireBenchmark fingerprint does not match independent Node oracle" >&2
    exit 1
}
[ "$swift_fingerprint_two" = "$oracle_fingerprint" ] || {
    echo "second WireBenchmark fingerprint does not match independent Node oracle" >&2
    exit 1
}
[ "$swift_fingerprint_one" = "$swift_fingerprint_two" ] || {
    echo "WireBenchmark fingerprint changed between runs" >&2
    exit 1
}

mutated_corpus=$(mktemp -d "$build_dir/corpus-fingerprint.XXXXXX")
trap 'rm -rf "$mutated_corpus"' EXIT
cp -R "$root/Benchmarks/Corpus/." "$mutated_corpus/"
printf 'X' >> "$mutated_corpus/payloads/advertise-small.json"
mutated_container_corpus="/workspace/.build/$(basename "$mutated_corpus")"
mutated_oracle=$(node "$root/Tests/Support/corpus-fingerprint.mjs" "$mutated_corpus")
mutated_swift=$(CONTAINER_RUNTIME="$container_runtime" \
    IMAGE="${IMAGE:-axoloty-dev}" BUILD_DIR="$build_dir" \
    CONTAINER_ENV_VARS=WIRE_BENCHMARK_CORPUS_DIR \
    WIRE_BENCHMARK_CORPUS_DIR="$mutated_container_corpus" \
    "$root/.devcontainer/run.sh" /workspace/.build/release/WireBenchmark --corpus-fingerprint)
[ "$mutated_swift" = "$mutated_oracle" ] || {
    echo "mutated WireBenchmark fingerprint does not match independent Node oracle" >&2
    exit 1
}
[ "$mutated_swift" != "$known_fingerprint" ] || {
    echo "payload mutation did not change the corpus fingerprint" >&2
    exit 1
}

# A malformed payload must fail the benchmark instead of producing a timing
# sample for a silently rejected decode.
failed_corpus=$(mktemp -d "$build_dir/corpus-operation-failure.XXXXXX")
trap 'rm -rf "$mutated_corpus" "$failed_corpus"' EXIT
cp -R "$root/Benchmarks/Corpus/." "$failed_corpus/"
printf 'not-json' >"$failed_corpus/payloads/advertise-small.json"
node --input-type=module - "$failed_corpus/manifest.json" <<'JS'
import fs from "node:fs";
const manifestPath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(manifestPath));
manifest.cases = manifest.cases.filter(item => item.id === "advertise-small");
fs.writeFileSync(manifestPath, JSON.stringify(manifest) + "\n");
JS
failed_container_corpus="/workspace/.build/$(basename "$failed_corpus")"
if failure_output=$(CONTAINER_RUNTIME="$container_runtime" \
    IMAGE="${IMAGE:-axoloty-dev}" BUILD_DIR="$build_dir" \
    CONTAINER_ENV_VARS=WIRE_BENCHMARK_CORPUS_DIR \
    WIRE_BENCHMARK_CORPUS_DIR="$failed_container_corpus" \
    "$root/.devcontainer/run.sh" /workspace/.build/release/WireBenchmark 2>&1); then
    echo "expected WireBenchmark to fail when dtoDecode rejects a corpus case" >&2
    exit 1
fi
printf '%s\n' "$failure_output" | grep -F "case 'advertise-small'" >/dev/null || {
    echo "benchmark failure did not identify the corpus case" >&2
    exit 1
}
printf '%s\n' "$failure_output" | grep -F "operation 'dtoDecode'" >/dev/null || {
    echo "benchmark failure did not identify the operation" >&2
    exit 1
}

node --input-type=module - <<'JS'
import assert from "node:assert/strict";
import { percentile, mad, compare } from "./Tests/Support/benchmark-wire.mjs";

const values = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
assert.equal(percentile(values, 50), 55);
assert.ok(Math.abs(percentile(values, 95) - 95.5) < 0.01);

const lowMad = [1000, 1005, 998, 1002, 1001];
assert.ok(mad(lowMad) / 1001 <= 0.05);
const highMad = [1000, 1200, 800, 1500, 600];
assert.ok(mad(highMad) / 1000 > 0.05);

const firstEnvironment = { corpusHash: "abc123" };
const secondEnvironment = { corpusHash: "def456" };
assert.notEqual(firstEnvironment.corpusHash, secondEnvironment.corpusHash);

const baseline = {
  environment: { corpusHash: "test123" },
  cases: [{
    caseId: "advertise-small",
    family: "ADV",
    sizeClass: "small",
    operations: { topicParse: { p50ns: 100, p95ns: 200, batchSize: 10000 } },
  }],
};
assert.deepEqual(JSON.parse(JSON.stringify(baseline)), baseline);

const changed = structuredClone(baseline);
changed.cases[0].operations.topicParse.p50ns = 200;
changed.cases[0].operations.topicParse.p95ns = 400;
assert.match(compare(changed, baseline), /BASELINE DRIFT/);

assert.match(compare(
  { environment: { corpusHash: "93eea5f6ced99549956392d934fb21310328cd4c14491f7fe44c451c8098d6ee" }, cases: [] },
  { environment: { corpusHash: "stale-baseline" }, cases: [] },
), /MISMATCH: corpus hash differs/);
assert.match(compare(
  { environment: { corpusHash: "93eea5f6ced99549956392d934fb21310328cd4c14491f7fe44c451c8098d6ee" }, cases: [] },
  { environment: {}, cases: [] },
), /MISMATCH: corpus hash differs/);
JS
sh -n "$script_dir/check-benchmark-wire.sh"
echo "SELF-TEST OK (17 checks passed, 0 failed)"
