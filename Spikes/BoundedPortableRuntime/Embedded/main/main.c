// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "esp_system.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_heap_trace.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include <stdint.h>
#include "BridgingHeader.h"

static heap_trace_record_t g1_heap_records[128];

void g1_print(const char *message) { esp_rom_printf("%s", message); }

void g1_print_uint(const char *label, unsigned int value) {
    esp_rom_printf("%s%u", label, value);
}

unsigned int g1_free_internal_heap(void) {
    return (unsigned int)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
}

unsigned int g1_min_free_internal_heap(void) {
    return (unsigned int)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
}

unsigned int g1_largest_internal_block(void) {
    return (unsigned int)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
}

unsigned int g1_main_stack_high_water(void) {
    return (unsigned int)uxTaskGetStackHighWaterMark(NULL);
}

unsigned int g1_main_stack_size(void) {
    return (unsigned int)CONFIG_ESP_MAIN_TASK_STACK_SIZE;
}

unsigned int g1_reset_reason(void) { return (unsigned int)esp_reset_reason(); }

unsigned int g1_board_revision(void) {
    esp_chip_info_t info;
    esp_chip_info(&info);
    return (unsigned int)info.revision;
}

unsigned int g1_flash_size(void) {
    uint32_t size = 0;
    return esp_flash_get_size(NULL, &size) == ESP_OK ? (unsigned int)size : 0;
}

unsigned int g1_time_microseconds(void) {
    return (unsigned int)esp_timer_get_time();
}

int g1_heap_trace_begin(void) {
    if (heap_trace_init_standalone(g1_heap_records, 128) != ESP_OK) return 0;
    return heap_trace_start(HEAP_TRACE_ALL) == ESP_OK;
}

unsigned int g1_heap_trace_end(void) {
    if (heap_trace_stop() != ESP_OK) return UINT32_MAX;
    return (unsigned int)heap_trace_get_count();
}

void app_main(void) {
    vTaskDelay(pdMS_TO_TICKS(1000));
    bounded_portable_runtime_probe();
}
