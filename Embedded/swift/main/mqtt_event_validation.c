// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "mqtt_event_validation.h"

#define NETWORK_MAX_TOPIC 257
#define NETWORK_MAX_PAYLOAD 2049

int axoloty_mqtt_event_data_is_valid(
    const void *topic, int topic_length,
    const void *data, int data_length,
    int total_data_length, int current_data_offset) {
    if (!topic || !data || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC ||
        data_length < 0 || data_length >= NETWORK_MAX_PAYLOAD ||
        total_data_length < 0 || total_data_length >= NETWORK_MAX_PAYLOAD ||
        current_data_offset < 0 || current_data_offset > total_data_length ||
        data_length > total_data_length - current_data_offset) {
        return 0;
    }

    // The static endpoint has no reassembly buffer. Require one complete
    // fragment instead of retaining partial untrusted data.
    return current_data_offset == 0 && data_length == total_data_length;
}
