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
    PRIV_REQUIRES idf_swift
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_BINARY_DIR}/empty_bridging_header.h
    SRCS ${AXOLOTY_WIRE_SOURCES}
)

# idf_swift adds the component bridge header as a public compile option.
# AxolotyWire needs no C bridge, and exporting its empty header overrides the
# application bridge in dependent Swift compiles.
set_property(TARGET ${COMPONENT_LIB} PROPERTY INTERFACE_COMPILE_OPTIONS "")

# Override the Swift module name to AxolotyWire (defaults to the CMake
# target name __idf_axoloty_wire otherwise).
target_compile_options(${COMPONENT_LIB} PRIVATE
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
# Publish that module under its importable name once this component is built.
add_custom_command(TARGET ${COMPONENT_LIB} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_BINARY_DIR}/${COMPONENT_LIB}.swiftmodule
        ${CMAKE_CURRENT_BINARY_DIR}/AxolotyWire.swiftmodule
    VERBATIM
)
