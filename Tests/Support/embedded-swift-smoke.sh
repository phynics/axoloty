#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build, flash, and monitor the ESP32-C6 Embedded Swift image (issue #321).
#
# Runs inside the $(IMAGE)-embedded container. Sources ESP-IDF, sets the
# target, builds, flashes, then captures serial output for up to 30 seconds
# looking for the AXOLOTY_SMOKE_OK marker emitted by Main.swift.
#
# Writes the monitor log to .testing/embedded/swift-smoke-log.txt.

set -eu

device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}"
smoke_log="$out_dir/swift-smoke-log.txt"
project_dir="${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}"
marker="AXOLOTY_SMOKE_OK"
deadline=30

if [ ! -e "$device" ]; then
    echo "SMOKE FAIL: $device does not exist (check CONTAINER_DEVICES)" >&2
    exit 1
fi

. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1

mkdir -p "$out_dir"
cd "$project_dir"

echo "== set-target =="
idf.py set-target esp32c6

echo "== build =="
idf.py build

echo "== flash =="
idf.py -p "$device" flash

echo "== monitor (deadline ${deadline}s, marker: ${marker}) =="
python3 - "$device" "$deadline" "$marker" "$smoke_log" <<'PY'
import serial, sys, time

device, deadline, marker, log_path = sys.argv[1:5]
deadline = int(deadline)

ser = serial.Serial(device, 115200, timeout=1)
ser.reset_input_buffer()

start = time.time()
lines = []
found = False

while time.time() - start < deadline:
    line = ser.readline().decode("utf-8", errors="replace").strip()
    if line:
        print(line)
        lines.append(line)
        if marker in line:
            found = True
            break

ser.close()

with open(log_path, "w") as f:
    f.write("\n".join(lines) + "\n")

if found:
    print("SMOKE OK")
    sys.exit(0)
else:
    print(f"SMOKE FAIL: marker not found within {deadline}s", file=sys.stderr)
    sys.exit(1)
PY
