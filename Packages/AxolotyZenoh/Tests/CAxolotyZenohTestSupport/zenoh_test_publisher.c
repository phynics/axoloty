// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_zenoh_test_publisher.h"

#include <stdlib.h>

#include <zenoh.h>

struct axoloty_zenoh_test_publisher {
    z_owned_session_t session;
};

/// The encoding label a test publisher attaches to a sample. `DEFAULT` sends
/// the Zenoh default label, as a peer that sets no encoding would.
enum axoloty_zenoh_test_publisher_encoding {
    AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_CBOR,
    AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_JSON,
    AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_DEFAULT,
};

static int32_t axoloty_zenoh_test_publisher_put_with_encoding(
    void *handle,
    const uint8_t *key,
    size_t key_length,
    const uint8_t *payload,
    size_t payload_length,
    enum axoloty_zenoh_test_publisher_encoding encoding_kind);

void *axoloty_zenoh_test_publisher_open(void) {
    struct axoloty_zenoh_test_publisher *publisher = malloc(sizeof(*publisher));
    if (publisher == NULL) {
        return NULL;
    }

    z_owned_config_t config;
    if (z_config_default(&config) != Z_OK) {
        free(publisher);
        return NULL;
    }
    if (zc_config_insert_json5(z_config_loan_mut(&config), Z_CONFIG_MODE_KEY, "\"peer\"") != Z_OK ||
        zc_config_insert_json5(z_config_loan_mut(&config), Z_CONFIG_MULTICAST_SCOUTING_KEY, "true") != Z_OK) {
        z_config_drop(z_config_move(&config));
        free(publisher);
        return NULL;
    }
    z_open_options_t options;
    z_open_options_default(&options);
    if (z_open(&publisher->session, z_config_move(&config), &options) != Z_OK) {
        z_session_drop(z_session_move(&publisher->session));
        free(publisher);
        return NULL;
    }
    return publisher;
}

int32_t axoloty_zenoh_test_publisher_put(void *handle,
                                         const uint8_t *key,
                                         size_t key_length,
                                         const uint8_t *payload,
                                         size_t payload_length) {
    return axoloty_zenoh_test_publisher_put_with_encoding(
        handle, key, key_length, payload, payload_length,
        AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_CBOR
    );
}

int32_t axoloty_zenoh_test_publisher_put_json(void *handle,
                                              const uint8_t *key,
                                              size_t key_length,
                                              const uint8_t *payload,
                                              size_t payload_length) {
    return axoloty_zenoh_test_publisher_put_with_encoding(
        handle, key, key_length, payload, payload_length,
        AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_JSON
    );
}

int32_t axoloty_zenoh_test_publisher_put_unlabeled(void *handle,
                                                   const uint8_t *key,
                                                   size_t key_length,
                                                   const uint8_t *payload,
                                                   size_t payload_length) {
    // Leaving the default label is what a peer that sets no encoding sends.
    return axoloty_zenoh_test_publisher_put_with_encoding(
        handle, key, key_length, payload, payload_length,
        AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_DEFAULT
    );
}

static int32_t axoloty_zenoh_test_publisher_put_with_encoding(
    void *handle,
    const uint8_t *key,
    size_t key_length,
    const uint8_t *payload,
    size_t payload_length,
    enum axoloty_zenoh_test_publisher_encoding encoding_kind) {
    struct axoloty_zenoh_test_publisher *publisher = handle;
    if (publisher == NULL || key == NULL || key_length == 0 ||
        (payload == NULL && payload_length != 0)) {
        return Z_EINVAL;
    }
    z_owned_keyexpr_t key_expr;
    z_result_t result = z_keyexpr_from_substr(&key_expr, (const char *)key, key_length);
    if (result != Z_OK) {
        return result;
    }
    z_owned_bytes_t bytes;
    result = z_bytes_copy_from_buf(&bytes, payload, payload_length);
    if (result != Z_OK) {
        z_keyexpr_drop(z_keyexpr_move(&key_expr));
        return result;
    }
    z_put_options_t options;
    z_put_options_default(&options);
    switch (encoding_kind) {
        case AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_CBOR: {
            z_owned_encoding_t cbor_encoding;
            z_encoding_clone(&cbor_encoding, z_encoding_application_cbor());
            options.encoding = z_encoding_move(&cbor_encoding);
            break;
        }
        case AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_JSON: {
            z_owned_encoding_t json_encoding;
            if (z_encoding_from_str(&json_encoding, "application/json") != Z_OK) {
                z_keyexpr_drop(z_keyexpr_move(&key_expr));
                z_bytes_drop(z_bytes_move(&bytes));
                return Z_EGENERIC;
            }
            options.encoding = z_encoding_move(&json_encoding);
            break;
        }
        case AXOLOTY_ZENOH_TEST_PUBLISHER_ENCODING_DEFAULT:
            break;
    }
    result = z_put(z_session_loan(&publisher->session),
                   z_keyexpr_loan(&key_expr),
                   z_bytes_move(&bytes),
                   &options);
    z_keyexpr_drop(z_keyexpr_move(&key_expr));
    return result;
}

void axoloty_zenoh_test_publisher_close(void *handle) {
    struct axoloty_zenoh_test_publisher *publisher = handle;
    if (publisher == NULL) {
        return;
    }
    z_close_options_t options;
    z_close_options_default(&options);
    (void)z_close(z_session_loan_mut(&publisher->session), &options);
    z_session_drop(z_session_move(&publisher->session));
    free(publisher);
}
