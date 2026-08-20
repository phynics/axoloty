# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

get_filename_component(SPIKE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(BOUND_PORTABLE_COMMON_SOURCES
    "${SPIKE_ROOT}/Sources/BoundedPortableRuntime/InlineStorage.swift"
    "${SPIKE_ROOT}/Sources/BoundedPortableRuntime/HandlerStorage.swift"
    "${SPIKE_ROOT}/Sources/BoundedPortableRuntime/ParserWorkspace.swift"
)

if(G1_MACRO_ATTEMPT)
    if(NOT DEFINED G1_MACRO_PLUGIN)
        message(FATAL_ERROR "G1_MACRO_PLUGIN is required for the macro consumer attempt")
    endif()
    set(BOUND_PORTABLE_SOURCES
        ${BOUND_PORTABLE_COMMON_SOURCES}
        "${CMAKE_CURRENT_LIST_DIR}/MacroAttempt.swift"
    )
else()
    set(BOUND_PORTABLE_SOURCES
        ${BOUND_PORTABLE_COMMON_SOURCES}
        "${CMAKE_CURRENT_LIST_DIR}/main.swift"
    )
endif()

idf_component_register(
    SRCS "main.c"
    PRIV_REQUIRES idf_swift
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
    SRCS ${BOUND_PORTABLE_SOURCES}
)

if(G1_MACRO_ATTEMPT)
    target_compile_options(
        ${COMPONENT_LIB}
        PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:-load-plugin-executable>"
            "$<$<COMPILE_LANGUAGE:Swift>:${G1_MACRO_PLUGIN}#BoundedPortableRuntimeMacros>"
    )
endif()

if(DEFINED G1_CAPACITY AND NOT G1_CAPACITY STREQUAL "0")
    if(NOT G1_CAPACITY MATCHES "^(1|4|16|64)$")
        message(FATAL_ERROR "G1_CAPACITY must be one of 0, 1, 4, 16, or 64")
    endif()
    target_compile_options(
        ${COMPONENT_LIB}
        PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:-DG1_CAPACITY_${G1_CAPACITY}>"
    )
endif()
