// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Bridging header exposing ESP-IDF C APIs to Embedded Swift.

#include <stdio.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "sdkconfig.h"

// C helpers for Swift logging (variadic functions like printf are unavailable
// in Embedded Swift).
void axoloty_print(const char *msg);
void axoloty_print_uint(const char *label, unsigned int value);
unsigned int axoloty_free_internal_heap(void);
unsigned int axoloty_min_free_internal_heap(void);
unsigned int axoloty_largest_internal_block(void);
unsigned int axoloty_main_stack_high_water(void);
unsigned int axoloty_main_stack_size(void);
unsigned int axoloty_reset_reason(void);
int axoloty_heap_trace_begin(void);
unsigned int axoloty_heap_trace_end(void);

// Synchronous, C-owned Wi-Fi/MQTT hardware-test façade. Callback data never
// crosses this boundary.
int axoloty_network_configured(void);
unsigned int axoloty_network_role(void);
unsigned int axoloty_network_scenario(void);
unsigned int axoloty_agent_test(unsigned int overall_deadline_ms);
unsigned int axoloty_network_prepare(unsigned int overall_deadline_ms);
int axoloty_network_copy_topic(unsigned char *buffer, int capacity);
int axoloty_network_copy_payload(unsigned char *buffer, int capacity);
int axoloty_mqtt_configure_last_will(const unsigned char *topic, int topic_length,
                                     const unsigned char *payload, int payload_length);
int axoloty_mqtt_connect_wait(unsigned int deadline_ms);
int axoloty_mqtt_subscribe_wait(const unsigned char *topic, int topic_length,
                                unsigned int deadline_ms);
int axoloty_mqtt_publish(const unsigned char *topic, int topic_length,
                        const unsigned char *payload, int payload_length);
int axoloty_mqtt_wait_loopback(unsigned int deadline_ms);
int axoloty_mqtt_reconnect_wait(unsigned int deadline_ms);
int axoloty_mqtt_disconnect(void);
unsigned int axoloty_network_cleanup(void);
