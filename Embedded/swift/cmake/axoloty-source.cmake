# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Boundary helpers for the Embedded Swift consumer. Every path that points
# into Axoloty Core is supplied by the caller; this file deliberately has no
# checkout-layout discovery logic.

function(axoloty_require_canonical_directory variable_name description out_name)
    if(NOT DEFINED ENV{${variable_name}} OR "$ENV{${variable_name}}" STREQUAL "")
        message(FATAL_ERROR
            "${variable_name} is required: supply the canonical ${description}"
        )
    endif()

    set(candidate "$ENV{${variable_name}}")
    if(NOT IS_ABSOLUTE "${candidate}")
        message(FATAL_ERROR
            "${variable_name} must be an absolute canonical path: ${candidate}"
        )
    endif()
    if(NOT IS_DIRECTORY "${candidate}")
        message(FATAL_ERROR
            "${variable_name} does not name a directory: ${candidate}"
        )
    endif()

    file(REAL_PATH "${candidate}" resolved)
    if(NOT "${candidate}" STREQUAL "${resolved}")
        message(FATAL_ERROR
            "${variable_name} must be canonical; resolved ${candidate} to ${resolved}"
        )
    endif()
    set("${out_name}" "${resolved}" PARENT_SCOPE)
endfunction()

function(axoloty_require_core_child variable_name relative_path out_name)
    axoloty_require_canonical_directory(
        "${variable_name}" "${relative_path}" "${out_name}"
    )
    set(child "$ENV{${variable_name}}")
    file(RELATIVE_PATH relative_to_core "${AXOLOTY_SOURCE_DIR}" "${child}")
    if(IS_ABSOLUTE "${relative_to_core}" OR
       "${relative_to_core}" STREQUAL ".." OR
       "${relative_to_core}" MATCHES "^\.\./")
        message(FATAL_ERROR
            "${variable_name} escapes AXOLOTY_SOURCE_DIR: ${child}"
        )
    endif()
    if(NOT "${relative_to_core}" STREQUAL "${relative_path}")
        message(FATAL_ERROR
            "${variable_name} must resolve to ${relative_path} under AXOLOTY_SOURCE_DIR; got ${relative_to_core}"
        )
    endif()
    set("${out_name}" "$ENV{${variable_name}}" PARENT_SCOPE)
endfunction()

function(axoloty_require_core_package package_name source_variable)
    set(package_dir "${AXOLOTY_SOURCE_DIR}/Packages/${package_name}")
    set(manifest "${package_dir}/Package.swift")
    if(NOT EXISTS "${manifest}")
        message(FATAL_ERROR
            "${package_name} package manifest is missing: ${manifest}"
        )
    endif()
    file(READ "${manifest}" manifest_text)
    if(NOT manifest_text MATCHES "Package[ \\t]*\\(")
        message(FATAL_ERROR
            "${package_name} package manifest is not a Swift package: ${manifest}"
        )
    endif()
    if(NOT manifest_text MATCHES "name:[ \\t]*\\\"${package_name}\\\"")
        message(FATAL_ERROR
            "${package_name} package manifest has an unexpected identity: ${manifest}"
        )
    endif()
    if(NOT IS_DIRECTORY "${${source_variable}}")
        message(FATAL_ERROR
            "${package_name} source directory is missing: ${${source_variable}}"
        )
    endif()
    file(GLOB package_sources "${${source_variable}}/*.swift")
    if(NOT package_sources)
        message(FATAL_ERROR
            "${package_name} source directory contains no Swift files: ${${source_variable}}"
        )
    endif()
endfunction()

axoloty_require_canonical_directory(
    AXOLOTY_SOURCE_DIR "the Axoloty Core checkout" AXOLOTY_SOURCE_DIR
)
axoloty_require_core_child(
    AXOLOTY_WIRE_SOURCE_DIR
    "Packages/AxolotyWire/Sources/AxolotyWire"
    AXOLOTY_WIRE_SOURCE_DIR
)
axoloty_require_core_child(
    AXOLOTY_OBJECT_MODEL_SOURCE_DIR
    "Packages/AxolotyObjectModel/Sources/AxolotyObjectModel"
    AXOLOTY_OBJECT_MODEL_SOURCE_DIR
)
axoloty_require_core_child(
    AXOLOTY_PROTOCOL_SOURCE_DIR
    "Packages/AxolotyProtocol/Sources/AxolotyProtocol"
    AXOLOTY_PROTOCOL_SOURCE_DIR
)
axoloty_require_core_child(
    AXOLOTY_COATY_MODELS_SOURCE_DIR
    "Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels"
    AXOLOTY_COATY_MODELS_SOURCE_DIR
)
axoloty_require_core_child(
    AXOLOTY_STATIC_RUNTIME_SOURCE_DIR
    "Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime"
    AXOLOTY_STATIC_RUNTIME_SOURCE_DIR
)
axoloty_require_core_package(AxolotyWire AXOLOTY_WIRE_SOURCE_DIR)
axoloty_require_core_package(AxolotyObjectModel AXOLOTY_OBJECT_MODEL_SOURCE_DIR)
axoloty_require_core_package(AxolotyProtocol AXOLOTY_PROTOCOL_SOURCE_DIR)
axoloty_require_core_package(AxolotyCoatyModels AXOLOTY_COATY_MODELS_SOURCE_DIR)
axoloty_require_core_package(AxolotyStaticRuntime AXOLOTY_STATIC_RUNTIME_SOURCE_DIR)

axoloty_require_canonical_directory(
    AXOLOTY_JSON_CORE_SOURCE_DIR "the resolved _JSONCore source directory" AXOLOTY_JSON_CORE_SOURCE_DIR
)
axoloty_require_canonical_directory(
    AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR
    "the caller-owned macro scratch directory"
    AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR
)
if(NOT DEFINED ENV{AXOLOTY_STATIC_RUNTIME_MACRO_TOOL} OR
   "$ENV{AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" STREQUAL "")
    message(FATAL_ERROR
        "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL is required: supply the built macro executable"
    )
endif()
set(AXOLOTY_STATIC_RUNTIME_MACRO_TOOL "$ENV{AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}")
if(NOT IS_ABSOLUTE "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" OR
   NOT EXISTS "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}")
    message(FATAL_ERROR
        "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL must be an existing absolute path: ${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}"
    )
endif()
file(REAL_PATH "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" AXOLOTY_STATIC_RUNTIME_MACRO_TOOL_REAL)
if(NOT "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" STREQUAL "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL_REAL}")
    message(FATAL_ERROR
        "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL must be canonical: ${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}"
    )
endif()
file(RELATIVE_PATH AXOLOTY_MACRO_RELATIVE_TO_SCRATCH
    "${AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR}"
    "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}"
)
if(IS_ABSOLUTE "${AXOLOTY_MACRO_RELATIVE_TO_SCRATCH}" OR
   "${AXOLOTY_MACRO_RELATIVE_TO_SCRATCH}" STREQUAL ".." OR
   "${AXOLOTY_MACRO_RELATIVE_TO_SCRATCH}" MATCHES "^\.\./")
    message(FATAL_ERROR
        "AXOLOTY_STATIC_RUNTIME_MACRO_TOOL must be inside AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR"
    )
endif()

if(NOT DEFINED ENV{AXOLOTY_CORE_SHA} OR "$ENV{AXOLOTY_CORE_SHA}" STREQUAL "")
    message(FATAL_ERROR "AXOLOTY_CORE_SHA is required for Embedded Swift provenance")
endif()
set(AXOLOTY_CORE_SHA "$ENV{AXOLOTY_CORE_SHA}")
string(LENGTH "${AXOLOTY_CORE_SHA}" AXOLOTY_CORE_SHA_LENGTH)
if(NOT AXOLOTY_CORE_SHA_LENGTH EQUAL 40 OR
   NOT AXOLOTY_CORE_SHA MATCHES "^[0-9a-fA-F]+$")
    message(FATAL_ERROR "AXOLOTY_CORE_SHA must be a 40-character commit SHA: ${AXOLOTY_CORE_SHA}")
endif()
if(NOT DEFINED ENV{AXOLOTY_CORE_DIRTY})
    message(FATAL_ERROR "AXOLOTY_CORE_DIRTY is required for Embedded Swift provenance")
endif()
set(AXOLOTY_CORE_DIRTY "$ENV{AXOLOTY_CORE_DIRTY}")
if(NOT AXOLOTY_CORE_DIRTY MATCHES "^(0|1)$")
    message(FATAL_ERROR "AXOLOTY_CORE_DIRTY must be 0 or 1: ${AXOLOTY_CORE_DIRTY}")
endif()
