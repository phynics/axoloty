# AxolotyObjectModel ESP-IDF component. It compiles the same bounded object
# foundation sources used by the standalone SwiftPM package and exports the
# importable AxolotyObjectModel module for static embedded consumers.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../../.."
    ABSOLUTE
)

file(GLOB AXOLOTY_OBJECT_MODEL_SOURCES
    "${AXOLOTY_ROOT}/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/*.swift"
)

if(NOT AXOLOTY_OBJECT_MODEL_SOURCES)
    message(FATAL_ERROR "No AxolotyObjectModel sources found at ${AXOLOTY_ROOT}/Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/")
endif()

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h "")

idf_component_register(
    SRCS "component_anchor.c"
    PRIV_REQUIRES idf_swift axoloty_wire json_core
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${AXOLOTY_OBJECT_MODEL_SOURCES}
)

# The model imports AxolotyWire. Make the module alias a hard compile-time
# prerequisite, not only a link dependency, for clean parallel builds.
idf_component_get_property(WIRE_COMPONENT_LIB axoloty_wire COMPONENT_LIB)
get_target_property(WIRE_COMPONENT_BINARY_DIR ${WIRE_COMPONENT_LIB} BINARY_DIR)
set(WIRE_MODULE_ALIAS
    "${WIRE_COMPONENT_BINARY_DIR}/AxolotyWire.swiftmodule"
)
if(TARGET axoloty_wire_module_alias)
    add_dependencies(axoloty_wire_module_alias ${WIRE_COMPONENT_LIB})
    add_dependencies(${COMPONENT_LIB} axoloty_wire_module_alias)
endif()
set_source_files_properties(${AXOLOTY_OBJECT_MODEL_SOURCES}
    PROPERTIES OBJECT_DEPENDS "${WIRE_MODULE_ALIAS}"
)
idf_component_get_property(JSON_CORE_COMPONENT_LIB json_core COMPONENT_LIB)
add_dependencies(${COMPONENT_LIB} ${JSON_CORE_COMPONENT_LIB})

set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-swift-version>"
    "$<$<COMPILE_LANGUAGE:Swift>:6>"
    "$<$<COMPILE_LANGUAGE:Swift>:-enable-experimental-feature>"
    "$<$<COMPILE_LANGUAGE:Swift>:Lifetimes>"
    "$<$<COMPILE_LANGUAGE:Swift>:-module-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:AxolotyObjectModel>"
)

target_include_directories(${COMPONENT_LIB} PUBLIC
    ${CMAKE_CURRENT_BINARY_DIR}
)

add_custom_command(TARGET ${COMPONENT_LIB} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${CMAKE_CURRENT_BINARY_DIR}/AxolotyObjectModel.swiftmodule
    VERBATIM
)
