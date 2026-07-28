# Component CMake for the Axoloty Embedded Swift app (issue #321).
#
# The main application component depends on the axoloty_wire component,
# which compiles AxolotyWire as a separate Embedded Swift module.
# Main.swift uses `import AxolotyWire` to access the wire codec.

get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../.."
    ABSOLUTE
)

idf_component_register(
    SRCS "log_helper.c"
    PRIV_INCLUDE_DIRS "."
    PRIV_REQUIRES idf_swift axoloty_wire
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
    SRCS
        ${CMAKE_CURRENT_LIST_DIR}/Main.swift
)
