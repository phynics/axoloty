#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
probe="$root/Spikes/BoundedPortableRuntime"
candidate=$(git -C "$root" rev-parse HEAD)
artifact="$root/.testing/g1-bounded-runtime/$candidate"
device=${AXOLOTY_DEVICE:-/dev/ttyACM0}
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

node "$probe/Evidence/assemble-hardware-evidence.mjs" "$root" "$artifact" "$candidate"

node "$probe/Evidence/validate-evidence.mjs" \
    "$probe/Evidence/evidence.schema.json" "$artifact/hardware-evidence.json"
node -e 'const report=require(process.argv[1]); process.exit(report.status === "passed" ? 0 : 1)' \
    "$artifact/hardware-evidence.json"
echo "PASS g1-bounded-runtime-device candidate=$candidate artifact=$artifact/hardware-evidence.json"
