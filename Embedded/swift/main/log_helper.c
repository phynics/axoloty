// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// C helper for Swift logging on ESP32-C6.
//
// Embedded Swift cannot call variadic C functions (printf, esp_rom_printf,
// ESP_LOGI). This wrapper provides a fixed-signature alternative that Swift
// can call directly through the bridging header.

#include "esp_rom_sys.h"

void axoloty_print(const char *msg) {
    esp_rom_printf("%s", msg);
}
