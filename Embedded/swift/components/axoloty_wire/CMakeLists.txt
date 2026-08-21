# AxolotyWire ESP-IDF component — compiles the real AxolotyWire Swift
# sources as a separate Embedded Swift module that the main application
# imports via `import AxolotyWire`.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../../.."
    ABSOLUTE
)

file(GLOB AXOLOTY_WIRE_SOURCES
    "${AXOLOTY_ROOT}/Packages/AxolotyWire/Sources/AxolotyWire/*.swift"
)

if(NOT AXOLOTY_WIRE_SOURCES)
    message(FATAL_ERROR "No AxolotyWire sources found at ${AXOLOTY_ROOT}/Packages/AxolotyWire/Sources/AxolotyWire/")
endif()

# Create an empty bridging header — AxolotyWire is pure Swift and needs
# no C interop. The idf_swift component requires a BRIDGING_HEADER.
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h "")

idf_component_register(
    SRCS "component_anchor.c"
    PRIV_REQUIRES idf_swift json_core
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${AXOLOTY_WIRE_SOURCES}
)

# PRIV_REQUIRES supplies include and link metadata, but Ninja may still start
# this Swift compile before json_core's POST_BUILD command has published the
# importable `_JSONCore.swiftmodule` alias. Make that compile-time ordering
# explicit so clean parallel builds cannot race the module copy.
idf_component_get_property(JSON_CORE_COMPONENT_LIB json_core COMPONENT_LIB)
add_dependencies(${COMPONENT_LIB} ${JSON_CORE_COMPONENT_LIB})

# idf_swift adds the component bridge header as a public compile option.
# AxolotyWire needs no C bridge, and exporting its empty header overrides the
# application bridge in dependent Swift compiles.
set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")

# Override the Swift module name to AxolotyWire (defaults to the CMake
# target name __idf_axoloty_wire otherwise).
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-swift-version>"
    "$<$<COMPILE_LANGUAGE:Swift>:6>"
    "$<$<COMPILE_LANGUAGE:Swift>:-module-name>"
    "$<$<COMPILE_LANGUAGE:Swift>:AxolotyWire>"
)

# Expose the .swiftmodule directory to dependent components.
# The swiftmodule is emitted into the component's build directory.
target_include_directories(${COMPONENT_LIB} PUBLIC
    ${CMAKE_CURRENT_BINARY_DIR}
)

# idf_component_register_swift writes the module file using the ESP-IDF target
# name, whereas dependent Swift code resolves the module by `-module-name`.
# Publish that module under its importable name as an explicit build output.
# A named target lets the Protocol component depend on the alias itself rather
# than merely on the Wire archive; the latter can start Protocol's Swift
# compile before this copy exists in a clean parallel build.
set(AXOLOTY_WIRE_MODULE_ALIAS
    "${CMAKE_CURRENT_BINARY_DIR}/AxolotyWire.swiftmodule"
)
add_custom_command(
    OUTPUT ${AXOLOTY_WIRE_MODULE_ALIAS}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${AXOLOTY_WIRE_MODULE_ALIAS}
    DEPENDS ${COMPONENT_LIB}
    VERBATIM
)
add_custom_target(axoloty_wire_module_alias
    DEPENDS ${AXOLOTY_WIRE_MODULE_ALIAS}
)
