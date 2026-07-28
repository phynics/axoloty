# CMake top-level project file for the Axoloty ESP32-C6 Embedded Swift image.
#
# This is a standalone ESP-IDF project that compiles AxolotyWire in Embedded
# Swift mode via the espressif/idf_swift component. AxolotyWire is compiled
# as a separate Swift module that the main application imports.

cmake_minimum_required(VERSION 3.29)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(axoloty-swift)

# ESP-IDF v5.4 discards .got/.got.plt in its generated sections.ld (the rule
# is explicitly marked TODO: GCC-382). Swift's prebuilt Unicode archive uses
# R_RISCV_CALL_PLT relocations, so GNU ld synthesizes .got.plt after ldgen's
# archive selectors have been applied. Patch only the generated build copy,
# immediately before the ELF link, and fail closed if the pinned template no
# longer matches.
idf_build_get_property(project_elf EXECUTABLE)
add_custom_command(TARGET ${project_elf} PRE_LINK
    COMMAND ${PYTHON} ${CMAKE_CURRENT_LIST_DIR}/main/patch_swift_got.py
        ${CMAKE_BINARY_DIR}/esp-idf/esp_system/ld/sections.ld
    VERBATIM
)
