# Component CMake for the Axoloty Embedded Swift app (issue #321).
#
# Registers the main component with ESP-IDF and uses the idf_swift component
# to compile Swift sources — including the actual AxolotyWire package — for
# the ESP32-C6 RISC-V target.
#
# The AxolotyWire sources are referenced via a relative path from this
# component directory to the workspace root, so they are compiled from the
# real Swift package, not a copy or C port.

# Resolve the workspace root (3 levels up from this file).
get_filename_component(AXOLOTY_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../../.."
    ABSOLUTE
)

# Collect all AxolotyWire Swift sources.
file(GLOB AXOLOTY_WIRE_SOURCES
    "${AXOLOTY_ROOT}/Packages/AxolotyWire/Sources/AxolotyWire/*.swift"
)

if(NOT AXOLOTY_WIRE_SOURCES)
    message(FATAL_ERROR "No AxolotyWire sources found at ${AXOLOTY_ROOT}/Packages/AxolotyWire/Sources/AxolotyWire/")
endif()

# Register the component with ESP-IDF. SRCS /dev/null because there are no
# C/C++ sources — only Swift sources registered below.
if(WIN32)
  set(devnull NUL)
else()
  set(devnull /dev/null)
endif()

idf_component_register(
    SRCS "log_helper.c"
    PRIV_INCLUDE_DIRS "."
    PRIV_REQUIRES idf_swift
)

# Configure Embedded Swift compilation.
idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
    SRCS
        ${CMAKE_CURRENT_LIST_DIR}/Main.swift
        ${AXOLOTY_WIRE_SOURCES}
)
