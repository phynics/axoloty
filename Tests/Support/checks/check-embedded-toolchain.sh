#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Embedded toolchain doctor for the ESP32-C6 image.
#
# Verifies every tool the embedded targets depend on is installed and
# reachable, and that the flashed device is accessible from the container.
# Runs inside the $(IMAGE)-embedded container (see the Makefile
# `embedded-toolchain-doctor` target).
#
# The Swift RISC-V cross-compile probe is informational only: Swift 6.3
# recognizes the riscv32-unknown-none-elf target triple but has no stdlib
# for it, so the probe is expected to fail. The C toolchain (ESP-IDF's
# RISC-V GCC) is sufficient for the smoke image; this is tracked for a later
# phase. See docs/embedded-toolchain.md.
#
# Prints EMBEDDED TOOLCHAIN OK and exits 0 when every required tool reports a
# version and /dev/ttyACM0 is readable and writable.

set -eu

device=${EMBEDDED_DEVICE:-/dev/ttyACM0}

fail() {
    echo "EMBEDDED TOOLCHAIN FAIL: $1" >&2
    exit 1
}

# 1. Source the ESP-IDF environment. The installer places export.sh at
#    $IDF_PATH/export.sh; it mutates PATH and sets IDF_PY/OPENOCD_* vars.
#    Silence the chatty stdout (it prints a banner and tips).
if [ ! -f "${IDF_PATH:-/opt/esp/idf}/export.sh" ]; then
    fail "ESP-IDF export.sh not found at ${IDF_PATH:-/opt/esp/idf}/export.sh"
fi
# shellcheck source=/dev/null
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1

# 2. Report versions. Each `command -v` is the gate; the --version line is the
#    evidence. `idf.py --version` prints the IDF release tag.
report() {
    name=$1
    shift
    cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "$name not found on PATH"
    fi
    printf '%-22s ' "$name"
    "$@" 2>&1 | head -n 1
}

echo "== Tool versions =="
report "idf.py" idf.py idf.py --version
report "riscv32-esp-elf-gcc" riscv32-esp-elf-gcc riscv32-esp-elf-gcc --version
report "openocd" openocd openocd --version
report "espflash" espflash espflash --version
report "cmake" cmake cmake --version
report "ninja" ninja ninja --version
echo

# 3. Device access. The Makefile passes /dev/ttyACM0 via CONTAINER_DEVICES;
#    confirm it exists and the container can read and write it.
echo "== Device access =="
if [ ! -e "$device" ]; then
    fail "$device does not exist in the container (check CONTAINER_DEVICES)"
fi
if [ ! -r "$device" ]; then
    fail "$device is not readable"
fi
if [ ! -w "$device" ]; then
    fail "$device is not writable"
fi
ls -l "$device"
echo

# 4. Swift RISC-V capability probe. Informational only — see file header.
echo "== Swift RISC-V probe (informational) =="
if swift_riscv_out=$(swiftc -target riscv32-unknown-none-elf \
        -parse-as-library -c /dev/null -o /tmp/swift-riscv-test.o 2>&1); then
    echo "Swift can cross-compile to riscv32-unknown-none-elf (unexpected)"
    swift_riscv_capable=true
else
    # Expected on Swift 6.3: "unable to load standard library libswiftCore".
    echo "Swift cannot cross-compile to riscv32-unknown-none-elf (known gap)"
    echo "swiftc output: ${swift_riscv_out}"
    swift_riscv_capable=false
fi
rm -f /tmp/swift-riscv-test.o
echo

echo "EMBEDDED TOOLCHAIN OK"
echo "swiftRiscvCapable=${swift_riscv_capable}"
