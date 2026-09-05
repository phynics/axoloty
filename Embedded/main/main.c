// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Minimal ESP32-C6 smoke program.
//
// Prints the ``AXOLOTY_SMOKE_OK`` marker through ESP-IDF's logging stack,
// flushes stdout, waits one second so a serial monitor is guaranteed to
// capture the line, then restarts the device. The smoke harness
// (Tests/Support/embedded/embedded-device-smoke.sh) greps the monitor output for the
// marker within a 30-second deadline.
//
// This is a C program rather than Embedded Swift because Swift 6.3 recognizes
// the ``riscv32-unknown-none-elf`` target triple but cannot cross-compile it
// (no stdlib for that target). The Swift entry point lives in smoke.swift
// and will replace this file once a RISC-V-capable Swift toolchain is
// available. See docs/embedded-toolchain.md.

#include <stdio.h>

#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "axoloty-smoke";

void app_main(void) {
    ESP_LOGI(TAG, "AXOLOTY_SMOKE_OK");
    fflush(stdout);
    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();
}
