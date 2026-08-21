# AxolotyProtocol ESP-IDF component. It compiles the same portable protocol
# sources used by the standalone SwiftPM package and exports the module for
# future static-runtime consumers without adding a second processor.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../../.."
    ABSOLUTE
)

file(GLOB AXOLOTY_PROTOCOL_SOURCES
    "${AXOLOTY_ROOT}/Packages/AxolotyProtocol/Sources/AxolotyProtocol/*.swift"
)

if(NOT AXOLOTY_PROTOCOL_SOURCES)
    message(FATAL_ERROR "No AxolotyProtocol sources found at ${AXOLOTY_ROOT}/Packages/AxolotyProtocol/Sources/AxolotyProtocol/")
endif()

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h "")

idf_component_register(
    SRCS "component_anchor.c"
    PRIV_REQUIRES idf_swift axoloty_wire json_core
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${AXOLOTY_PROTOCOL_SOURCES}
)

idf_component_get_property(WIRE_COMPONENT_LIB axoloty_wire COMPONENT_LIB)
add_dependencies(${COMPONENT_LIB} ${WIRE_COMPONENT_LIB})
idf_component_get_property(JSON_CORE_COMPONENT_LIB json_core COMPONENT_LIB)
add_dependencies(${COMPONENT_LIB} ${JSON_CORE_COMPONENT_LIB})

set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-swift-version>"
    "$<$<COMPILE_LANGUAGE:Swift>:6>"
    "$<$<COMPILE_LANGUAGE:Swift>:-module-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:AxolotyProtocol>"
)

target_include_directories(${COMPONENT_LIB} PUBLIC
    ${CMAKE_CURRENT_BINARY_DIR}
)

add_custom_command(TARGET ${COMPONENT_LIB} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${CMAKE_CURRENT_BINARY_DIR}/AxolotyProtocol.swiftmodule
    VERBATIM
)
