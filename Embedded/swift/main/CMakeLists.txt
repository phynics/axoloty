# Component CMake for the Axoloty Embedded Swift app (issue #321).
#
# The main application component depends on the axoloty_wire component,
# which compiles AxolotyWire and AxolotyProtocol as separate Embedded Swift
# modules. Main.swift uses `import AxolotyWire`; ProtocolModuleConsumer.swift
# imports AxolotyProtocol and exercises its public profile symbol so the
# application proves module discovery and linkage, not just compilation.

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
    ${CMAKE_CURRENT_LIST_DIR}/EmbeddedMQTTClient.swift
    ${CMAKE_CURRENT_LIST_DIR}/ProtocolModuleConsumer.swift
    ${CMAKE_CURRENT_LIST_DIR}/StaticDeviceAgent.swift
)
set(AXOLOTY_CORPUS_SOURCE "${CMAKE_CURRENT_BINARY_DIR}/GeneratedCorpus.swift")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    ${AXOLOTY_ROOT}/Tests/Support/generate-embedded-corpus.mjs
    ${AXOLOTY_ROOT}/Benchmarks/Corpus/manifest.json
    ${AXOLOTY_ROOT}/Benchmarks/Corpus/payloads/*.json
)
execute_process(
    COMMAND node
        ${AXOLOTY_ROOT}/Tests/Support/generate-embedded-corpus.mjs
        ${AXOLOTY_ROOT}/Benchmarks/Corpus/manifest.json
        ${AXOLOTY_CORPUS_SOURCE}
    RESULT_VARIABLE AXOLOTY_CORPUS_GENERATION_RESULT
)
if(NOT AXOLOTY_CORPUS_GENERATION_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to generate Embedded Swift corpus vectors")
endif()
list(APPEND AXOLOTY_SWIFT_SOURCES ${AXOLOTY_CORPUS_SOURCE})
if(AXOLOTY_SWIFT_UNICODE_LINKER_PROBE)
    list(APPEND AXOLOTY_SWIFT_SOURCES
        ${CMAKE_CURRENT_LIST_DIR}/UnicodeLinkerProbe.swift
    )
endif()

idf_component_register(
    SRCS "log_helper.c" "network_bootstrap.c" "runtime_identity.c"
    PRIV_INCLUDE_DIRS "." "${CMAKE_CURRENT_BINARY_DIR}"
    PRIV_REQUIRES
        idf_swift
        axoloty_wire
        axoloty_protocol
        esp_system
        esp_timer
        heap
        esp_rom
        freertos
        log
        esp_wifi
        esp_event
        esp_netif
        nvs_flash
        mqtt
    LDFRAGMENTS "linker.lf"
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
    SRCS ${AXOLOTY_SWIFT_SOURCES}
)

# StaticDeviceAgent consumes the noncopyable ProtocolProcessor from the
# protocol component. Explicitly enable the same lifetime feature for the
# application consumer; otherwise the standalone protocol check would not
# prove the actual ESP-IDF consumer build.
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-enable-experimental-feature>"
    "$<$<COMPILE_LANGUAGE:Swift>:Lifetimes>"
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
