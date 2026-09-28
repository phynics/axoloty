// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_TEST_PUBLISHER_H
#define AXOLOTY_ZENOH_TEST_PUBLISHER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opens a local Zenoh peer used only to publish receive-test samples.
void *axoloty_zenoh_test_publisher_open(void);

/// Publishes caller bytes without façade key/payload limits for inbound tests.
int32_t axoloty_zenoh_test_publisher_put(void *publisher,
                                         const uint8_t *key,
                                         size_t key_length,
                                         const uint8_t *payload,
                                         size_t payload_length);

/// Closes and releases a test publisher returned by open.
void axoloty_zenoh_test_publisher_close(void *publisher);

#ifdef __cplusplus
}
#endif

#endif
