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
# Reset the device and capture serial output via pyserial (idf.py monitor
# requires a TTY which non-interactive shells don't provide).
esptool.py --port "$device" run >/dev/null 2>&1 || true
python3 -c "
import serial, time, json, sys, os

ser = serial.Serial('$device', 115200, timeout=1)
start = time.time()
lines = []

while time.time() - start < $deadline:
    data = ser.readline()
    if not data:
        continue
    line = data.decode('utf-8', errors='replace').strip()
    if not line:
        continue
    lines.append(line)
    print(line, flush=True)
    if '\"benchmark\":\"complete\"' in line:
        break

ser.close()

# Parse JSON Lines and write structured output.
results = []
for line in lines:
    # ESP-IDF log format: 'I (123) tag: {...}'
    # Extract the JSON part after the tag.
    idx = line.find('{')
    if idx < 0:
        continue
    json_str = line[idx:]
    try:
        obj = json.loads(json_str)
        results.append(obj)
    except:
        pass

out_dir = os.environ.get('SER_DIR', '/workspace/.testing/benchmarks/device')
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, 'device-benchmark.json'), 'w') as f:
    json.dump(results, f, indent=2)

# Also write raw log.
with open(os.path.join(out_dir, 'device-benchmark-raw.txt'), 'w') as f:
    f.write('\n'.join(lines))

# Check for completion marker.
completed = any(r.get('benchmark') == 'complete' for r in results)
if not completed:
    print('BENCHMARK WIRE DEVICE FAIL: no completion marker within ${deadline}s', file=sys.stderr)
    sys.exit(1)

print('BENCHMARK WIRE DEVICE OK')
" || fail "capture/parse failed"

echo "results: $out_dir/device-benchmark.json"
echo "raw:     $out_dir/device-benchmark-raw.txt"

# Run idf.py size for static analysis.
echo "== size report =="
idf.py size 2>&1 | tee "$out_dir/size-report.txt" || true
idf.py size-components 2>&1 | tee "$out_dir/size-components.txt" || true

# Reset the device after benchmark.
esptool.py --port "$device" run >/dev/null 2>&1 || true
