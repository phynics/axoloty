#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Device wire benchmark orchestration for issue #302.
#
# Builds, flashes, and captures the ESP32-C6 device benchmark firmware.
# The firmware emits JSON Lines over serial; this script captures them,
# parses the results, and writes structured output.
#
# Runs via rootful Podman (needs --privileged + /dev/ttyACM0 access).

set -eu

device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/benchmarks/$(git rev-parse --short HEAD 2>/dev/null || echo unknown)/device}"
project_dir="${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/benchmark}"
deadline=120  # seconds to wait for benchmark completion
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

fail() {
    echo "BENCHMARK WIRE DEVICE FAIL: $1" >&2
    exit 1
}

if [ ! -e "$device" ]; then
    fail "$device does not exist"
fi

# Source ESP-IDF.
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1

mkdir -p "$out_dir"
ser_dir="$out_dir"
export SER_DIR="$ser_dir"

cd "$project_dir"

echo "== set-target =="
idf.py set-target esp32c6

echo "== build =="
idf.py build

echo "== flash =="
idf.py -p "$device" flash

echo "== capture (deadline ${deadline}s) =="
# Reset the device and capture serial output without requiring an interactive
# idf.py monitor.
esptool.py --port "$device" run >/dev/null 2>&1 || true
SERIAL_TOOLS="$support_dir/serial-tools.mjs" node --input-type=module - "$device" "$deadline" "$ser_dir" <<'JS' || fail "capture/parse failed"
import fs from "node:fs"; const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const [device,deadline,out]=process.argv.slice(2), lines=[]; const captured=await captureSerial(device,Number(deadline),line=>{lines.push(line);console.log(line);}); const results=lines.flatMap(line=>{const i=line.indexOf("{");if(i<0)return[];try{return[JSON.parse(line.slice(i))];}catch{return[];}});fs.writeFileSync(`${out}/device-benchmark.json`,JSON.stringify(results,null,2)+"\n");fs.writeFileSync(`${out}/device-benchmark-raw.txt`,lines.join("\n"));if(!results.some(r=>r.benchmark==="complete")){console.error(`BENCHMARK WIRE DEVICE FAIL: no completion marker within ${deadline}s`);process.exit(1);}console.log("BENCHMARK WIRE DEVICE OK");
JS

echo "results: $out_dir/device-benchmark.json"
echo "raw:     $out_dir/device-benchmark-raw.txt"

# Run idf.py size for static analysis.
echo "== size report =="
idf.py size 2>&1 | tee "$out_dir/size-report.txt" || true
idf.py size-components 2>&1 | tee "$out_dir/size-components.txt" || true

# Reset the device after benchmark.
esptool.py --port "$device" run >/dev/null 2>&1 || true
