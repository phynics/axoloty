// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Bridging header exposing ESP-IDF C APIs to Embedded Swift.
//
// This header is imported by the Swift compiler via
// idf_component_register_swift(BRIDGING_HEADER ...). It provides the
// C function declarations needed by Main.swift and future Swift device
// code. Only headers that are needed should be listed here to keep
// compile times reasonable.

#include <stdio.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "sdkconfig.h"

// C helper for Swift logging (variadic functions like printf are unavailable
// in Embedded Swift).
void axoloty_print(const char *msg);
