#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Flash a previously built external firmware checkout and validate its serial
# smoke protocol. Device privileges are supplied by the outer container
# runner. This script never invokes sudo or rebuilds the firmware.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
build_dir=${EMBEDDED_BUILD_DIR:-"/workspace/.build/external-firmware/$proof_run_id"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$build_dir/evidence"}
manifest="$evidence_dir/consumer-preparation.json"
device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
serial_log="$evidence_dir/serial.log"
smoke_result="$evidence_dir/smoke-result.json"
deadline=${EMBEDDED_DEADLINE:-120}

if [ ! -e "$device" ]; then
    echo "error: serial device is unavailable: $device" >&2
    echo "hint: pass EMBEDDED_DEVICE=/dev/ttyACM0 or use the NixOS sudo command in the manual" >&2
    exit 1
fi

if [ ! -f "$manifest" ] || [ ! -f "$build_dir/flash_args" ] || \
    [ ! -s "$build_dir/axoloty-swift.bin" ]; then
    echo "error: flash metadata or axoloty-swift.bin is missing; run tools/build.sh first" >&2
    exit 1
fi

idf_path=${IDF_PATH:-/opt/esp/idf}
# shellcheck source=/dev/null
. "$idf_path/export.sh" >/dev/null 2>&1

mkdir -p "$evidence_dir"
set +e
chip_info=$(esptool.py --port "$device" chip_id 2>&1)
chip_status=$?
set -e
printf '%s\n' "$chip_info" > "$evidence_dir/chip-info.txt"
if [ "$chip_status" -ne 0 ] || ! printf '%s\n' "$chip_info" | grep -Eiq 'ESP32-C6'; then
    echo "error: selected device is not an ESP32-C6 (see $evidence_dir/chip-info.txt)" >&2
    exit 1
fi

artifact="$build_dir/axoloty-swift.bin"
if ! grep -Fq -- "$artifact" "$build_dir/flash_args" && \
    ! grep -Fq -- "$(basename -- "$artifact")" "$build_dir/flash_args"; then
    echo "error: flash_args does not reference the built axoloty-swift.bin" >&2
    exit 1
fi
if ! (
    cd "$build_dir"
    python3 "$idf_path/components/esptool_py/esptool/esptool.py" \
        --chip esp32c6 --port "$device" \
        --before default_reset --after hard_reset write_flash @flash_args
); then
    echo "error: flashing failed for $device" >&2
    exit 1
fi

echo "== monitor (deadline ${deadline}s, smoke protocol) =="
set +e
timeout "$deadline" idf.py -B "$build_dir" -p "$device" monitor > "$serial_log" 2>&1
monitor_status=$?
set -e
set +e
node "$script_dir/validate-smoke.mjs" "$serial_log" "$smoke_result" "$device" "$deadline"
validation_status=$?
set -e
if [ "$validation_status" -ne 0 ]; then
    echo "error: embedded-swift-smoke-v2 validation failed (see $smoke_result)" >&2
    exit "$validation_status"
fi
if [ "$monitor_status" -ne 0 ] && [ "$monitor_status" -ne 124 ]; then
    echo "error: ESP-IDF monitor failed with status $monitor_status" >&2
    exit 1
fi
node "$script_dir/write-go-proof.mjs" \
    "$evidence_dir/provenance.json" "$smoke_result" \
    "$evidence_dir/chip-info.txt" "$evidence_dir/go-proof.json"
echo "External firmware flash and smoke validation passed: $device"
