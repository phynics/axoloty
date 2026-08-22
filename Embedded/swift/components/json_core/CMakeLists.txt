# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Builds the pinned swift-json _JSONCore sources as a separate Embedded Swift
# module so the production AxolotyWire component uses the same tokenizer as the
# standalone SwiftPM package.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../../.."
    ABSOLUTE
)

set(JSON_CORE_ROOT
    "${AXOLOTY_ROOT}/.build/checkouts/swift-json/Sources/_JSONCore"
)
if(NOT IS_DIRECTORY "${JSON_CORE_ROOT}")
    message(FATAL_ERROR
        "Pinned swift-json _JSONCore sources not found at ${JSON_CORE_ROOT}; "
        "run the checked-in SwiftPM resolution before configuring Embedded Swift."
    )
endif()
file(GLOB JSON_CORE_SOURCES
    "${JSON_CORE_ROOT}/*.swift"
    "${JSON_CORE_ROOT}/Parser/*.swift"
    "${JSON_CORE_ROOT}/SIMD/*.swift"
)
list(APPEND JSON_CORE_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/EmbeddedJSONTokenizerResult.swift"
)

if(NOT JSON_CORE_SOURCES)
    message(FATAL_ERROR "Pinned swift-json _JSONCore sources not found at ${JSON_CORE_ROOT}")
endif()

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h "")

idf_component_register(
    SRCS "component_anchor.c"
    PRIV_REQUIRES idf_swift
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${JSON_CORE_SOURCES}
)

set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-swift-version>"
    "$<$<COMPILE_LANGUAGE:Swift>:6>"
    "$<$<COMPILE_LANGUAGE:Swift>:-module-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:_JSONCore>"
    "$<$<COMPILE_LANGUAGE:Swift>:-package-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:IkigaJSON>"
    "$<$<COMPILE_LANGUAGE:Swift>:-enable-experimental-feature>"
    "$<$<COMPILE_LANGUAGE:Swift>:Lifetimes>"
)
target_include_directories(${COMPONENT_LIB} PUBLIC
    ${CMAKE_CURRENT_BINARY_DIR}
)

add_custom_command(TARGET ${COMPONENT_LIB} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${CMAKE_CURRENT_BINARY_DIR}/_JSONCore.swiftmodule
    VERBATIM
)
