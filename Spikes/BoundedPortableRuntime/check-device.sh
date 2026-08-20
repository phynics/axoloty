#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedPortableRuntime"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g1-bounded-runtime/$candidate"
device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
embedded_evidence="$artifact/embedded-evidence.json"
hardware_runs="$artifact/hardware-runs"

[ "${AXOLOTY_DEVCONTAINER:-0}" = 1 ] || {
    echo "check-device.sh must run in the pinned development container" >&2
    exit 2
}
[ -c "$device" ] || { echo "device is unavailable: $device" >&2; exit 1; }
[ -f "$embedded_evidence" ] || {
    echo "run g1-bounded-runtime-embedded for candidate $candidate first" >&2
    exit 1
}
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
rm -rf "$hardware_runs"
mkdir -p "$hardware_runs"

for capacity in 1 4 16 64; do
    build="$artifact/embedded-build"
    (cd "$probe/Embedded" && idf.py -B "$build" -DG1_CAPACITY="$capacity" reconfigure build) \
        >"$hardware_runs/capacity-$capacity-build.log" 2>&1
    [ -f "$build/flash_args" ] || { echo "missing build for capacity $capacity" >&2; exit 1; }
    for run in 1 2; do
        run_prefix="$hardware_runs/capacity-$capacity-run-$run"
        (
            cd "$build"
            python3 "$IDF_PATH/components/esptool_py/esptool/esptool.py" \
                --chip esp32c6 --port "$device" --before default_reset --after hard_reset \
                write_flash @flash_args
        ) >"$run_prefix-flash.log" 2>&1
        node "$probe/Evidence/capture-device.mjs" "$device" 60 \
            "$run_prefix.json" "$run_prefix-serial.log"
    done
done

CANDIDATE_SHA="$candidate" ROOT="$root" ARTIFACT="$artifact" node <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = process.env.ROOT;
const artifact = process.env.ARTIFACT;
const budgetPath = path.join(root, 'Benchmarks/Baselines/budget-manifest.json');
const budgetSource = fs.readFileSync(budgetPath);
const budgetManifest = JSON.parse(budgetSource);
const embedded = JSON.parse(fs.readFileSync(path.join(artifact, 'embedded-evidence.json')));
const median = values => {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
const relativeMAD = values => {
  const center = median(values);
  return center === 0 ? 0 : median(values.map(value => Math.abs(value - center))) / center;
};
const configurations = [1, 4, 16, 64].map(capacity => {
  const crossBuild = embedded.configurations.find(value => value.capacity === capacity);
  const runs = [1, 2].map(run => JSON.parse(fs.readFileSync(
    path.join(artifact, 'hardware-runs', `capacity-${capacity}-run-${run}.json`), 'utf8'
  )));
  return {
    capacity,
    crossBuild,
    runs: runs.map(run => ({...run, relativeMAD: relativeMAD(run.rateSamplesPerSecond)})),
  };
});
const first = configurations[0].runs[0];
const noiseLimit = budgetManifest.noisePolicy.relativeMAD;
const passed = configurations.every(configuration => configuration.runs.every(run =>
  run.initializationAllocations === 0 &&
  run.steadyStateAllocations === 0 &&
  run.mainStackHighWater >= 4000 &&
  run.sustainedRatePerSecond >= 125 &&
  run.relativeMAD <= noiseLimit &&
  configuration.crossBuild.firmwareBytes <= 1048576
));
const report = {
  schemaVersion: 1,
  evidenceKind: 'hardware',
  candidateSha: process.env.CANDIDATE_SHA,
  status: passed ? 'passed' : 'failed',
  board: {target: 'esp32c6', revision: String(first.boardRevision), flashBytes: first.flashBytes},
  budget: {
    manifestSha256: crypto.createHash('sha256').update(budgetSource).digest('hex'),
    relativeMAD: noiseLimit,
    allocationRule: budgetManifest.noisePolicy.allocationVariance,
    stackReserveBytes: 4000,
  },
  configurations,
};
fs.writeFileSync(path.join(artifact, 'hardware-evidence.json'), JSON.stringify(report, null, 2) + '\n');
NODE

node "$probe/Evidence/validate-evidence.mjs" \
    "$probe/Evidence/evidence.schema.json" "$artifact/hardware-evidence.json"
node -e 'const report=require(process.argv[1]); process.exit(report.status === "passed" ? 0 : 1)' \
    "$artifact/hardware-evidence.json"
echo "PASS g1-bounded-runtime-device candidate=$candidate artifact=$artifact/hardware-evidence.json"
