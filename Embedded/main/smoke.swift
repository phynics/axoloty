// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Embedded Swift smoke entry point for ESP32-C6.
//
// Swift 6.3 recognizes the ``riscv32-unknown-none-elf`` target triple but
// cannot cross-compile: the standard library is unavailable for that target,
// and ``-parse-as-library`` does not bypass the requirement. A custom Swift
// toolchain with RISC-V backend support or a nightly snapshot is needed to
// compile this file.
//
// See ``docs/embedded-toolchain.md`` for the current toolchain status and
// the path to full Embedded Swift support.

@_cdecl("app_main")
func app_main() -> Int32 {
    // Once cross-compilation is available, this will print the success marker
    // via ESP-IDF's logging infrastructure and restart the device.
    return 0
}
