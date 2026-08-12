// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "runtime_identity.h"

#include <string.h>

static int is_allowed_override_character(unsigned char character) {
    return (character >= 'A' && character <= 'Z') ||
        (character >= 'a' && character <= 'z') ||
        (character >= '0' && character <= '9') ||
        character == '.' || character == '_' || character == '-';
}

int axoloty_runtime_identity_prepare(
    const char *override,
    axoloty_runtime_mac_reader read_mac,
    void *context,
    char *output,
    size_t output_size) {
    if (!override || !output || output_size == 0) return 0;

    size_t override_length = strlen(override);
    if (override_length > AXOLOTY_RUNTIME_IDENTITY_MAX_LENGTH) return 0;
    for (size_t index = 0; index < override_length; ++index) {
        if (!is_allowed_override_character((unsigned char)override[index])) return 0;
    }

    if (override_length > 0) {
        if (override_length + 1 > output_size) return 0;
        memcpy(output, override, override_length + 1);
        return 1;
    }

    if (!read_mac) return 0;
    uint8_t mac[6];
    if (!read_mac(mac, context)) return 0;
    static const char hex[] = "0123456789abcdef";
    static const char prefix[] = "axoloty-";
    const size_t prefix_length = sizeof(prefix) - 1;
    const size_t identity_length = prefix_length + (sizeof(mac) * 2);
    if (identity_length + 1 > output_size) return 0;

    memcpy(output, prefix, prefix_length);
    for (size_t index = 0; index < sizeof(mac); ++index) {
        output[prefix_length + (index * 2)] = hex[(mac[index] >> 4) & 0x0f];
        output[prefix_length + (index * 2) + 1] = hex[mac[index] & 0x0f];
    }
    output[identity_length] = '\0';
    return 1;
}
