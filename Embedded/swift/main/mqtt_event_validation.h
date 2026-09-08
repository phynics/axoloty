// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_MQTT_EVENT_VALIDATION_H
#define AXOLOTY_MQTT_EVENT_VALIDATION_H

#include <stddef.h>

/// Returns true only for a bounded, complete MQTT data event.
int axoloty_mqtt_event_data_is_valid(
    const void *topic, int topic_length,
    const void *data, int data_length,
    int total_data_length, int current_data_offset);

#endif
