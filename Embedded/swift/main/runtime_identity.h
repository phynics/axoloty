// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_RUNTIME_IDENTITY_H
#define AXOLOTY_RUNTIME_IDENTITY_H

#include <stddef.h>
#include <stdint.h>

#define AXOLOTY_RUNTIME_IDENTITY_MAX_LENGTH 63U

typedef int (*axoloty_runtime_mac_reader)(uint8_t mac[6], void *context);

int axoloty_runtime_identity_prepare(
    const char *override,
    axoloty_runtime_mac_reader read_mac,
    void *context,
    char *output,
    size_t output_size);

#endif
