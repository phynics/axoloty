#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${BENCHMARK_OUTPUT_DIR:-$script_dir/.testing/benchmarks/$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}; baseline=$script_dir/Benchmarks/Baselines/wire-baseline.json; mkdir -p "$out_dir"
command -v taskset >/dev/null 2>&1 || { echo "BENCHMARK WIRE FAIL: taskset not found (install util-linux)" >&2; exit 1; }
binary=$script_dir/.build/release/WireBenchmark; [ -x "$binary" ] || (cd "$script_dir" && swift build -c release --product WireBenchmark)
for i in 1 2 3 4 5; do taskset -c 0 "$binary" > "$out_dir/run-$i.json" 2>/dev/null || { echo "BENCHMARK WIRE FAIL: run $i failed" >&2; exit 1; }; done
WIRE_TOOLS="$script_dir/Support/benchmark-wire.mjs" node --input-type=module - "$out_dir" "$baseline" <<'JS'
import fs from "node:fs";
const { aggregate, compare } = await import(process.env.WIRE_TOOLS);
const dir=process.argv[2], baseline=process.argv[3], result=aggregate(dir); fs.writeFileSync(`${dir}/wire-baseline.json`,JSON.stringify(result,null,2)+"\n");
if(result.noisy?.length) { console.error(`BENCHMARK WIRE FAIL: noisy results (MAD > 5%):\n${result.noisy.join("\n")}`); process.exit(1); }
let base; try { base=JSON.parse(fs.readFileSync(baseline)); } catch { base=null; }
if(!base||!("cases" in base)){fs.writeFileSync(baseline,JSON.stringify(result,null,2)+"\n");console.log(`BASELINE CREATED at ${baseline}`);} else {const message=compare(result,base);if(message!=="MATCH"){console.error(message);process.exit(1);}console.log("Baseline matches within tolerance.");}
JS
echo "BENCHMARK WIRE OK"
