# AxolotyStaticRuntime ESP-IDF component. The component compiles the same
# fixed, Foundation-free runtime source used by its standalone SwiftPM target.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../../.."
    ABSOLUTE
)

set(AXOLOTY_STATIC_RUNTIME_SOURCES
    "${AXOLOTY_ROOT}/Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime/StaticRuntime.swift"
)
if(NOT EXISTS "${AXOLOTY_STATIC_RUNTIME_SOURCES}")
    message(FATAL_ERROR "No AxolotyStaticRuntime source found at ${AXOLOTY_STATIC_RUNTIME_SOURCES}")
endif()

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h "")

idf_component_register(
    SRCS "component_anchor.c"
    PRIV_REQUIRES idf_swift axoloty_protocol axoloty_wire
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${AXOLOTY_STATIC_RUNTIME_SOURCES}
)

idf_component_get_property(PROTOCOL_COMPONENT_LIB axoloty_protocol COMPONENT_LIB)
add_dependencies(${COMPONENT_LIB} axoloty_protocol_module_alias ${PROTOCOL_COMPONENT_LIB})

set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-swift-version>"
    "$<$<COMPILE_LANGUAGE:Swift>:6>"
    "$<$<COMPILE_LANGUAGE:Swift>:-enable-experimental-feature>"
    "$<$<COMPILE_LANGUAGE:Swift>:Lifetimes>"
    "$<$<COMPILE_LANGUAGE:Swift>:-module-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:AxolotyStaticRuntime>"
)

target_include_directories(${COMPONENT_LIB} PUBLIC
    ${CMAKE_CURRENT_BINARY_DIR}
)

set(AXOLOTY_STATIC_RUNTIME_MODULE_ALIAS
    "${CMAKE_CURRENT_BINARY_DIR}/AxolotyStaticRuntime.swiftmodule"
)
add_custom_command(
    OUTPUT ${AXOLOTY_STATIC_RUNTIME_MODULE_ALIAS}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${AXOLOTY_STATIC_RUNTIME_MODULE_ALIAS}
    DEPENDS ${COMPONENT_LIB}
    VERBATIM
)
add_custom_target(axoloty_static_runtime_module_alias
    DEPENDS ${AXOLOTY_STATIC_RUNTIME_MODULE_ALIAS}
)
