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
    PRIV_REQUIRES idf_swift axoloty_wire axoloty_object_model json_core
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${AXOLOTY_PROTOCOL_SOURCES}
)

idf_component_get_property(WIRE_COMPONENT_LIB axoloty_wire COMPONENT_LIB)
get_target_property(WIRE_COMPONENT_BINARY_DIR ${WIRE_COMPONENT_LIB} BINARY_DIR)
set(WIRE_MODULE_ALIAS
    "${WIRE_COMPONENT_BINARY_DIR}/AxolotyWire.swiftmodule"
)
if(TARGET axoloty_wire_module_alias)
    add_dependencies(axoloty_wire_module_alias ${WIRE_COMPONENT_LIB})
    add_dependencies(${COMPONENT_LIB} axoloty_wire_module_alias)
endif()
set_source_files_properties(${AXOLOTY_PROTOCOL_SOURCES}
    PROPERTIES OBJECT_DEPENDS "${WIRE_MODULE_ALIAS}"
)
idf_component_get_property(OBJECT_MODEL_COMPONENT_LIB axoloty_object_model COMPONENT_LIB)
get_target_property(OBJECT_MODEL_COMPONENT_BINARY_DIR ${OBJECT_MODEL_COMPONENT_LIB} BINARY_DIR)
set(OBJECT_MODEL_MODULE_ALIAS
    "${OBJECT_MODEL_COMPONENT_BINARY_DIR}/AxolotyObjectModel.swiftmodule"
)
if(TARGET axoloty_object_model_module_alias)
    add_dependencies(axoloty_object_model_module_alias ${OBJECT_MODEL_COMPONENT_LIB})
    add_dependencies(${COMPONENT_LIB} axoloty_object_model_module_alias)
endif()
set_source_files_properties(${AXOLOTY_PROTOCOL_SOURCES}
    APPEND PROPERTIES OBJECT_DEPENDS "${OBJECT_MODEL_MODULE_ALIAS}"
)
idf_component_get_property(JSON_CORE_COMPONENT_LIB json_core COMPONENT_LIB)
add_dependencies(${COMPONENT_LIB} ${JSON_CORE_COMPONENT_LIB})

set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-swift-version>"
    "$<$<COMPILE_LANGUAGE:Swift>:6>"
    # ProtocolProcessor and its borrowed action seam use the Embedded Swift
    # lifetime model. Keep the ESP-IDF component on the same compiler feature
    # set as the standalone protocol build.
    "$<$<COMPILE_LANGUAGE:Swift>:-enable-experimental-feature>"
    "$<$<COMPILE_LANGUAGE:Swift>:Lifetimes>"
    "$<$<COMPILE_LANGUAGE:Swift>:-module-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:AxolotyProtocol>"
)

target_include_directories(${COMPONENT_LIB} PUBLIC
    ${CMAKE_CURRENT_BINARY_DIR}
)

set(AXOLOTY_PROTOCOL_MODULE_ALIAS
    "${CMAKE_CURRENT_BINARY_DIR}/AxolotyProtocol.swiftmodule"
)
add_custom_command(
    OUTPUT ${AXOLOTY_PROTOCOL_MODULE_ALIAS}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${AXOLOTY_PROTOCOL_MODULE_ALIAS}
    DEPENDS ${COMPONENT_LIB}
    VERBATIM
)
add_custom_target(axoloty_protocol_module_alias
    DEPENDS ${AXOLOTY_PROTOCOL_MODULE_ALIAS}
)
