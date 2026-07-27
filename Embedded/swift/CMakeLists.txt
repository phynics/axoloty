# CMake top-level project file for the Axoloty ESP32-C6 Embedded Swift image.
#
# This is a standalone ESP-IDF project that compiles AxolotyWire in Embedded
# Swift mode via the espressif/idf_swift component. The app entry point
# is Main.swift, which calls AxolotyWire types directly — no C port.
#
# See docs/embedded-toolchain.md for build instructions.

cmake_minimum_required(VERSION 3.29)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(axoloty-swift)
