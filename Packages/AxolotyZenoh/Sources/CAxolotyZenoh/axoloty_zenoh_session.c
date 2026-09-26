// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_zenoh.h"

#include <string.h>

#include <zenoh.h>

// The façade owns a fixed registry of session slots. Session lifecycle is
// serialized by its caller (the host runtime's single owner), so the registry
// carries no locks: the embedded backend has no threading machinery, and a
// lock here would be host policy rather than façade behavior.
struct axoloty_zenoh_session {
    z_owned_session_t zenoh_session;
    bool open;
};

static struct axoloty_zenoh_session g_sessions[AXOLOTY_ZENOH_MAX_SESSIONS];

// The façade never dereferences a caller-supplied handle before proving it
// names a registry slot. A foreign pointer is rejected by identity alone.
static struct axoloty_zenoh_session *axoloty_zenoh_slot(const axoloty_zenoh_session_t *session) {
    if (session == NULL) {
        return NULL;
    }
    for (size_t index = 0; index < AXOLOTY_ZENOH_MAX_SESSIONS; index++) {
        if (session == &g_sessions[index]) {
            return &g_sessions[index];
        }
    }
    return NULL;
}

// Endpoints become JSON5 string values, so only characters that a quoted JSON5
// string can carry without escaping are admissible. The façade refuses to
// escape rather than growing an unbounded serializer.
static bool axoloty_zenoh_endpoint_is_valid(const uint8_t *endpoint, uint32_t length) {
    if (length == 0) {
        return true;
    }
    if (endpoint == NULL || length > (uint32_t)AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES) {
        return false;
    }
    for (uint32_t index = 0; index < length; index++) {
        uint8_t byte = endpoint[index];
        if (byte < 0x21 || byte > 0x7E || byte == '"' || byte == '\\') {
            return false;
        }
    }
    return true;
}

static z_result_t axoloty_zenoh_open_zenoh_session(struct axoloty_zenoh_session *slot,
                                                    const axoloty_zenoh_config_t *config) {
    z_owned_config_t zenoh_config;
    if (z_config_default(&zenoh_config) != Z_OK) {
        return Z_EGENERIC;
    }

    z_result_t result = zc_config_insert_json5(
        z_config_loan_mut(&zenoh_config),
        Z_CONFIG_MODE_KEY,
        config->mode == AXOLOTY_ZENOH_MODE_CLIENT ? "\"client\"" : "\"peer\""
    );
    if (result != Z_OK) {
        z_config_drop(z_config_move(&zenoh_config));
        return result;
    }

    result = zc_config_insert_json5(
        z_config_loan_mut(&zenoh_config),
        Z_CONFIG_MULTICAST_SCOUTING_KEY,
        config->multicast_scouting_enabled ? "true" : "false"
    );
    if (result != Z_OK) {
        z_config_drop(z_config_move(&zenoh_config));
        return result;
    }

    if (config->connect_endpoint_length > 0) {
        // `["<endpoint>"]` is at most the endpoint plus four delimiters and a
        // terminator. The endpoint contains no quote or backslash, so the
        // array is valid JSON5 without escaping.
        char json[AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES + 5];
        size_t length = config->connect_endpoint_length;
        json[0] = '[';
        json[1] = '"';
        memcpy(json + 2, config->connect_endpoint, length);
        json[2 + length] = '"';
        json[3 + length] = ']';
        json[4 + length] = '\0';
        result = zc_config_insert_json5(z_config_loan_mut(&zenoh_config), Z_CONFIG_CONNECT_KEY, json);
        if (result != Z_OK) {
            z_config_drop(z_config_move(&zenoh_config));
            return result;
        }
    }

    z_open_options_t options;
    z_open_options_default(&options);
    result = z_open(&slot->zenoh_session, z_config_move(&zenoh_config), &options);
    if (result != Z_OK) {
        // z_open consumed the configuration and leaves the session in its
        // gravestone state; dropping the gravestone is a no-op that keeps the
        // slot ready for a later open.
        z_session_drop(z_session_move(&slot->zenoh_session));
        return result;
    }
    return Z_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_open(const axoloty_zenoh_config_t *config,
                                          axoloty_zenoh_session_t **out_session) {
    if (out_session == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    *out_session = NULL;
    if (config == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (config->mode != AXOLOTY_ZENOH_MODE_CLIENT && config->mode != AXOLOTY_ZENOH_MODE_PEER) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!axoloty_zenoh_endpoint_is_valid(config->connect_endpoint, config->connect_endpoint_length)) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }

    struct axoloty_zenoh_session *slot = NULL;
    for (size_t index = 0; index < AXOLOTY_ZENOH_MAX_SESSIONS; index++) {
        if (!g_sessions[index].open) {
            slot = &g_sessions[index];
            break;
        }
    }
    if (slot == NULL) {
        return AXOLOTY_ZENOH_CAPACITY_EXCEEDED;
    }

    if (axoloty_zenoh_open_zenoh_session(slot, config) != Z_OK) {
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    slot->open = true;
    *out_session = slot;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_close(axoloty_zenoh_session_t *session) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!slot->open) {
        return AXOLOTY_ZENOH_NOT_OPEN;
    }

    z_close_options_t options;
    z_close_options_default(&options);
    z_result_t result = z_close(z_session_loan_mut(&slot->zenoh_session), &options);
    z_session_drop(z_session_move(&slot->zenoh_session));
    slot->open = false;
    return result == Z_OK ? AXOLOTY_ZENOH_OK : AXOLOTY_ZENOH_TRANSPORT_ERROR;
}

axoloty_zenoh_result_t axoloty_zenoh_state(const axoloty_zenoh_session_t *session,
                                           axoloty_zenoh_session_state_t *out_state) {
    if (out_state == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    *out_state = AXOLOTY_ZENOH_SESSION_CLOSED;
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    *out_state = slot->open ? AXOLOTY_ZENOH_SESSION_OPEN : AXOLOTY_ZENOH_SESSION_CLOSED;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_publish(const axoloty_zenoh_session_t *session,
                                             const uint8_t *key,
                                             uint32_t key_length,
                                             const uint8_t *payload,
                                             uint32_t payload_length) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!slot->open) {
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    if (key == NULL || key_length == 0 || key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (payload == NULL && payload_length != 0) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (payload_length > AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (z_keyexpr_is_canon((const char *)key, key_length) != Z_OK) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    for (uint32_t index = 0; index < key_length; index++) {
        if (key[index] == 0) {
            return AXOLOTY_ZENOH_INVALID_ARGUMENT;
        }
    }

    z_owned_keyexpr_t key_expr;
    if (z_keyexpr_from_substr(&key_expr, (const char *)key, key_length) != Z_OK) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }

    z_owned_bytes_t owned_payload;
    if (z_bytes_copy_from_buf(&owned_payload, payload, payload_length) != Z_OK) {
        z_keyexpr_drop(z_keyexpr_move(&key_expr));
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }

    z_put_options_t options;
    z_put_options_default(&options);
    z_result_t result = z_put(
        z_session_loan(&slot->zenoh_session),
        z_keyexpr_loan(&key_expr),
        z_bytes_move(&owned_payload),
        &options
    );
    z_keyexpr_drop(z_keyexpr_move(&key_expr));
    return result == Z_OK ? AXOLOTY_ZENOH_OK : AXOLOTY_ZENOH_TRANSPORT_ERROR;
}
