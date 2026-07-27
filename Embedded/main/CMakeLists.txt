# Component CMake for the smoke app's main component.
#
# Registers main.c as the only source and exposes its include dir. The
# smoke.swift placeholder is intentionally not listed in SRCS: Swift 6.3
# cannot cross-compile to riscv32-unknown-none-elf, so building it would
# fail the ESP-IDF build. It is tracked in the tree for the future Embedded
# Swift path (see docs/embedded-toolchain.md).

idf_component_register(SRCS "main.c"
                       INCLUDE_DIRS ".")
