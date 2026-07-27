# CMake top-level project file for the Axoloty ESP32-C6 smoke image.
#
# Minimal ESP-IDF project: it pulls in IDF's project.cmake, which drives the
# component discovery, sdkconfig generation, and the RISC-V cross-build. The
# app entry point and smoke marker live in main/main.c; a Swift placeholder
# (main/smoke.swift) is included for future Embedded Swift support but is not
# compiled yet — see docs/embedded-toolchain.md.

cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(axoloty-smoke)
