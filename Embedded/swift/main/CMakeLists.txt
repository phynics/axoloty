# Component CMake for the Axoloty Embedded Swift app (issue #321).
#
# The main application component depends on the axoloty_wire component,
# which compiles AxolotyWire as a separate Embedded Swift module.
# Main.swift uses `import AxolotyWire` to access the wire codec.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../.."
    ABSOLUTE
)

option(AXOLOTY_SWIFT_UNICODE_LINKER_PROBE
    "Compile a String-normalization probe to verify the Unicode linker setup"
    OFF
)
set(AXOLOTY_SWIFT_SOURCES
    ${CMAKE_CURRENT_LIST_DIR}/Main.swift
)
if(AXOLOTY_SWIFT_UNICODE_LINKER_PROBE)
    list(APPEND AXOLOTY_SWIFT_SOURCES
        ${CMAKE_CURRENT_LIST_DIR}/UnicodeLinkerProbe.swift
    )
endif()

idf_component_register(
    SRCS "log_helper.c"
    PRIV_INCLUDE_DIRS "."
    PRIV_REQUIRES
        idf_swift
        axoloty_wire
        esp_system
        esp_timer
        heap
        esp_rom
        freertos
        log
    LDFRAGMENTS "linker.lf"
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
    SRCS ${AXOLOTY_SWIFT_SOURCES}
)

# String-backed validation paths use normalization data that is shipped as a
# separate Embedded Swift archive. linker.lf maps its GOT/PLT input sections
# into ESP-IDF's dram0_data output before the generic /DISCARD/ rule.
target_link_libraries(${COMPONENT_LIB} PUBLIC
    /usr/lib/swift/embedded/riscv32-none-none-eabi/libswiftUnicodeDataTables.a
)
if(AXOLOTY_SWIFT_UNICODE_LINKER_PROBE)
    target_link_options(${COMPONENT_LIB} PUBLIC
        -u axoloty_unicode_linker_probe
    )
endif()
