#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build, flash, and monitor the ESP32-C6 smoke image with an explicit deadline.
#
# Runs inside the $(IMAGE)-embedded container (see the Makefile
# `embedded-device-smoke` target). Sources ESP-IDF, sets the target, builds,
# flashes, then monitors for up to 30 seconds looking for the AXOLOTY_SMOKE_OK
# marker emitted by Embedded/main/main.c. The monitor deadline is hard: if
# the marker does not appear, the script fails. After the probe the device is
# reset out of the smoke app so the board is left in a clean state.
#
# Writes the monitor log to .testing/embedded/smoke-log.txt (outside /tmp).

set -eu

device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}"
smoke_log="$out_dir/smoke-log.txt"
project_dir="${EMBEDDED_PROJECT_DIR:-/workspace/Embedded}"
marker="AXOLOTY_SMOKE_OK"
# Hard deadline (seconds). The smoke app prints the marker within ~1s of boot,
# so 30s is generous while still bounding the run.
deadline=30

if [ ! -e "$device" ]; then
    echo "SMOKE FAIL: $device does not exist (check CONTAINER_DEVICES)" >&2
    exit 1
fi

# Source ESP-IDF for idf.py and esptool.py.
# shellcheck source=/dev/null
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
# idf.py monitor runs until interrupted. `timeout` enforces the deadline; the
# pipe captures output for both the marker check and the persisted log.
# pipefail + `|| true` so a non-zero exit from timeout (124) does not abort
# the script before we inspect the log.
set +e
timeout "$deadline" idf.py -p "$device" monitor 2>&1 | tee "$smoke_log"
set -e

if grep -q "$marker" "$smoke_log"; then
    echo "SMOKE OK"
    # Leave the board in a clean state (exit the smoke app).
    esptool.py --port "$device" run >/dev/null 2>&1 || true
    exit 0
fi

echo "SMOKE FAIL: marker not found within ${deadline}s" >&2
echo "log: $smoke_log" >&2
# Reset the board even on failure so it is not left in the monitor.
esptool.py --port "$device" run >/dev/null 2>&1 || true
exit 1
