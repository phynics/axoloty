# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

get_filename_component(SPIKE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(BOUND_PORTABLE_SOURCES
    "${SPIKE_ROOT}/Sources/BoundedPortableRuntime/InlineStorage.swift"
    "${SPIKE_ROOT}/Sources/BoundedPortableRuntime/HandlerStorage.swift"
    "${SPIKE_ROOT}/Sources/BoundedPortableRuntime/ParserWorkspace.swift"
    "${CMAKE_CURRENT_LIST_DIR}/main.swift"
)

idf_component_register(
    SRCS "main.c"
    PRIV_REQUIRES idf_swift
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
    SRCS ${BOUND_PORTABLE_SOURCES}
)
