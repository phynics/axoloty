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
/// this sample on any route. The bytes are not decoded here.
int32_t axoloty_zenoh_test_publisher_put(void *publisher,
                                         const uint8_t *key,
                                         size_t key_length,
                                         const uint8_t *payload,
                                         size_t payload_length);

/// Publishes caller bytes labelled `application/json`.
///
/// A receiver admits this sample on any route, because the Zenoh `Encoding`
/// hint is advisory and admission follows the validated route. The non-CBOR
/// label is counted as a diagnostic; the bytes are never decoded here.
int32_t axoloty_zenoh_test_publisher_put_json(void *publisher,
                                              const uint8_t *key,
                                              size_t key_length,
                                              const uint8_t *payload,
                                              size_t payload_length);

/// Publishes caller bytes with no explicit Zenoh `Encoding`.
///
/// The peer uses the Zenoh default (`zenoh/bytes`), which is what a publisher
/// that sets no label sends. A receiver still admits the sample and decodes it
/// by route; the bytes are never decoded here.
int32_t axoloty_zenoh_test_publisher_put_unlabeled(void *publisher,
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
