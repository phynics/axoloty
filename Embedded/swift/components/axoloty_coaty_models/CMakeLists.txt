# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# AxolotyCoatyModels ESP-IDF component. Compile the same bounded first-party
# model sources used by SwiftPM and publish an importable module for consumers.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../../.."
    ABSOLUTE
)

file(GLOB AXOLOTY_COATY_MODELS_SOURCES
    "${AXOLOTY_ROOT}/Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels/*.swift"
)

if(NOT AXOLOTY_COATY_MODELS_SOURCES)
    message(FATAL_ERROR "No AxolotyCoatyModels sources found at ${AXOLOTY_ROOT}/Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels/")
endif()

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h "")

idf_component_register(
    SRCS "component_anchor.c"
    PRIV_REQUIRES idf_swift axoloty_object_model axoloty_wire json_core
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${AXOLOTY_COATY_MODELS_SOURCES}
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
set_source_files_properties(${AXOLOTY_COATY_MODELS_SOURCES}
    PROPERTIES OBJECT_DEPENDS "${OBJECT_MODEL_MODULE_ALIAS}"
)

# AxolotyObjectModel's public module imports AxolotyWire. The object-model
# component's private wire dependency does not make that transitive module
# search path or its alias visible to this Swift compile, so declare the
# transitive dependency explicitly and order both the module lookup and
# source compilation on the published AxolotyWire module.
idf_component_get_property(WIRE_COMPONENT_LIB axoloty_wire COMPONENT_LIB)
get_target_property(WIRE_COMPONENT_BINARY_DIR ${WIRE_COMPONENT_LIB} BINARY_DIR)
set(WIRE_MODULE_ALIAS
    "${WIRE_COMPONENT_BINARY_DIR}/AxolotyWire.swiftmodule"
)
if(TARGET axoloty_wire_module_alias)
    add_dependencies(axoloty_wire_module_alias ${WIRE_COMPONENT_LIB})
    add_dependencies(${COMPONENT_LIB} axoloty_wire_module_alias)
endif()
set_source_files_properties(${AXOLOTY_COATY_MODELS_SOURCES}
    APPEND PROPERTIES OBJECT_DEPENDS "${WIRE_MODULE_ALIAS}"
)

# AxolotyWire imports the pinned `_JSONCore` module. Keep its published module
# directory and build completion visible here as well; loading AxolotyWire
# through AxolotyObjectModel otherwise fails in a clean embedded build.
idf_component_get_property(JSON_CORE_COMPONENT_LIB json_core COMPONENT_LIB)
get_target_property(JSON_CORE_COMPONENT_BINARY_DIR ${JSON_CORE_COMPONENT_LIB} BINARY_DIR)
set(JSON_CORE_MODULE_ALIAS
    "${JSON_CORE_COMPONENT_BINARY_DIR}/_JSONCore.swiftmodule"
)
add_dependencies(${COMPONENT_LIB} ${JSON_CORE_COMPONENT_LIB})
set_source_files_properties(${AXOLOTY_COATY_MODELS_SOURCES}
    APPEND PROPERTIES OBJECT_DEPENDS "${JSON_CORE_MODULE_ALIAS}"
)

set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-swift-version>"
    "$<$<COMPILE_LANGUAGE:Swift>:6>"
    "$<$<COMPILE_LANGUAGE:Swift>:-enable-experimental-feature>"
    "$<$<COMPILE_LANGUAGE:Swift>:Lifetimes>"
    "$<$<COMPILE_LANGUAGE:Swift>:-module-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:AxolotyCoatyModels>"
)

target_include_directories(${COMPONENT_LIB} PUBLIC
    ${CMAKE_CURRENT_BINARY_DIR}
    ${WIRE_COMPONENT_BINARY_DIR}
    ${JSON_CORE_COMPONENT_BINARY_DIR}
)

set(AXOLOTY_COATY_MODELS_MODULE_ALIAS
    "${CMAKE_CURRENT_BINARY_DIR}/AxolotyCoatyModels.swiftmodule"
)
add_custom_command(
    OUTPUT ${AXOLOTY_COATY_MODELS_MODULE_ALIAS}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${AXOLOTY_COATY_MODELS_MODULE_ALIAS}
    DEPENDS ${COMPONENT_LIB}
    VERBATIM
)
add_custom_target(axoloty_coaty_models_module_alias
    DEPENDS ${AXOLOTY_COATY_MODELS_MODULE_ALIAS}
)
