// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// C helpers for Swift logging and testing on ESP32-C6.
//
// Embedded Swift cannot call variadic C functions (printf, esp_rom_printf,
// ESP_LOGI). These wrappers provide fixed-signature alternatives that Swift
// can call directly through the bridging header.

#include "esp_rom_sys.h"

void axoloty_print(const char *msg) {
    esp_rom_printf("%s", msg);
}

void axoloty_print_uint(const char *label, unsigned int value) {
    esp_rom_printf("%s%u", label, value);
}
