# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Device benchmark component for ESP32-C6 (issue #302).
#
# Mirrors AxolotyWire's zero-allocation JSON scanning algorithms in C,
# measures on-device latency/heap/stack, and emits JSON Lines over serial.
# Swift 6.3 cannot cross-compile to riscv32-unknown-none-elf (see #297),
# so this C port is used as a representative measurement. When Swift
# RISC-V support is available, this can be replaced with the actual
# AxolotyWire Swift code.

idf_component_register(SRCS "benchmark_main.c"
                       INCLUDE_DIRS ".")
