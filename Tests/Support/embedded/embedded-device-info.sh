#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Query the attached ESP32-C6 and record a device manifest.
#
# Runs inside the $(IMAGE)-embedded container (see the Makefile
# `embedded-device-info` target). Sources ESP-IDF for esptool.py, then queries
# the chip via espflash (primary) and esptool.py (fallback), captures the USB
# serial from udev, and writes both a structured JSON manifest and the raw
# tool output under .testing/embedded/ (outside /tmp, so it survives the
# container). boardModel is left empty — it is the silkscreen/declared carrier
# model and is filled in manually.
#
# Prints DEVICE INFO RECORDED and the manifest path on success.

set -eu

device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}"
manifest="$out_dir/device-manifest.json"
raw="$out_dir/device-info-raw.txt"

if [ ! -e "$device" ]; then
    echo "DEVICE INFO FAIL: $device does not exist (check CONTAINER_DEVICES)" >&2
    exit 1
fi

# Source ESP-IDF so esptool.py is on PATH.
# shellcheck source=/dev/null
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1

mkdir -p "$out_dir"
: > "$raw"

# Capture helpers. Each query writes a tagged section into the raw log and
# echoes its first-line result on stdout for parsing.
raw_section() {
    printf '\n===== %s =====\n' "$1" >>"$raw"
    shift
    "$@" >>"$raw" 2>&1 || true
}

chip_model=""
chip_revision=""
mac_address=""
flash_id=""
flash_size=""
usb_serial=""

echo "Querying $device via espflash..."
if raw_section "espflash board-info" \
        espflash board-info --port "$device"; then
    # `espflash board-info` prints human-readable lines like:
    #   Chip type:         esp32c6 (revision v0.0)
    #   Crystal frequency: 40 MHz
    #   MAC address:       aa:bb:cc:dd:ee:ff
    board_info=$(grep -E 'Chip type:|revision|MAC address:|Flash size' "$raw" 2>/dev/null || true)
    chip_model=$(printf '%s\n' "$board_info" | sed -n 's/.*Chip type:[[:space:]]*//p' | head -n1)
    chip_revision=$(printf '%s\n' "$board_info" | sed -n 's/.*(revision \(v[0-9.]*\)).*/\1/p' | head -n1)
    mac_address=$(printf '%s\n' "$board_info" | sed -n 's/.*MAC address:[[:space:]]*//p' | head -n1)
    flash_size=$(printf '%s\n' "$board_info" | sed -n 's/.*Flash size:[[:space:]]*//p' | head -n1)
fi

# esptool.py fallback for chip_id / flash_id, which espflash may not expose
# in every release.
echo "Querying $device via esptool.py..."
if raw_section "esptool chip_id" \
        esptool.py --port "$device" chip_id; then
    if [ -z "$chip_model" ]; then
        chip_model=$(sed -n 's/.*Chip is \([^ ]*\) .*/\1/p' "$raw" | tail -n1)
    fi
    mac_address=${mac_address:-$(sed -n 's/.*MAC: \([0-9a-f:]*\).*/\1/p' "$raw" | tail -n1)}
fi
if raw_section "esptool flash_id" \
        esptool.py --port "$device" flash_id; then
    flash_id=${flash_id:-$(sed -n 's/.*Manufacturer: \([0-9a-fx]*\).*/\1/p' "$raw" | tail -n1)}
    flash_size=${flash_size:-$(sed -n 's/.*Detected flash size: \([^ ]*\).*/\1/p' "$raw" | tail -n1)}
fi

# USB serial from udev. May be absent on some kernels; leave empty rather than
# fail — it is a convenience correlation, not an acceptance gate.
if command -v udevadm >/dev/null 2>&1; then
    usb_serial=$(udevadm info --query=property --name="$device" 2>/dev/null \
        | sed -n 's/^ID_SERIAL_SHORT=//p' | head -n1) || usb_serial=""
fi

# Capture toolchain versions for the manifest's toolchain block.
idf_ver=$(idf.py --version 2>&1 | head -n1 | sed 's/^ *//')
gcc_ver=$(riscv32-esp-elf-gcc --version 2>&1 | head -n1)
openocd_ver=$(openocd --version 2>&1 | head -n1)
espflash_ver=$(espflash --version 2>&1 | head -n1)

# Swift RISC-V probe mirrors check-embedded-toolchain.sh: informational, the
# C toolchain is the gate.
swift_riscv_capable=false
if swiftc_out=$(swiftc -target riscv32-unknown-none-elf \
        -parse-as-library -c /dev/null -o /tmp/swift-riscv-test.o 2>&1); then
    swift_riscv_capable=true
fi
rm -f /tmp/swift-riscv-test.o

# Write the manifest. Single-quoted static scaffolding + appended dynamic
# values keeps the script portable (no jq dependency). Trailing comma on
# the last toolchain field is avoided by ordering fields deliberately.
cat >"$manifest" <<EOF
{
  "\$comment": "Populated by make embedded-device-info. Do not edit manually.",
  "device": {
    "chipModel": "${chip_model}",
    "chipRevision": "${chip_revision}",
    "macAddress": "${mac_address}",
    "flashId": "${flash_id}",
    "flashSize": "${flash_size}",
    "usbSerial": "${usb_serial}",
    "boardModel": ""
  },
  "toolchain": {
    "espIdfVersion": "${idf_ver}",
    "riscvGccVersion": "${gcc_ver}",
    "openocdVersion": "${openocd_ver}",
    "espflashVersion": "${espflash_ver}",
    "swiftRiscvCapable": ${swift_riscv_capable}
  },
  "capturedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "DEVICE INFO RECORDED"
echo "manifest: $manifest"
echo "raw:      $raw"
