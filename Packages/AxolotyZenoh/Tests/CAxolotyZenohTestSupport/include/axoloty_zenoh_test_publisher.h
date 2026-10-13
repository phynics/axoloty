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

/// Publishes caller bytes labelled `application/cbor`.
///
/// Zenoh carries only `axoloty/1` CBOR, so the receive-side façade admits
/// this sample. The bytes are not decoded here.
int32_t axoloty_zenoh_test_publisher_put(void *publisher,
                                         const uint8_t *key,
                                         size_t key_length,
                                         const uint8_t *payload,
                                         size_t payload_length);

/// Publishes caller bytes labelled `application/json`.
///
/// The façade must drop this sample as an unsupported encoding; the bytes are
/// never admitted to a receive queue.
int32_t axoloty_zenoh_test_publisher_put_json(void *publisher,
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
