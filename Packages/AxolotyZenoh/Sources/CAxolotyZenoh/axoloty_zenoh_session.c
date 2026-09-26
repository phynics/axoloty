// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "axoloty_zenoh.h"

#include <stdatomic.h>
#include <string.h>

#include <zenoh.h>

// The façade owns a fixed registry of session slots. Session lifecycle is
// serialized by its caller (the host runtime's single owner), so the registry
// carries no locks: the embedded backend has no threading machinery, and a
// lock here would be host policy rather than façade behavior.
struct axoloty_zenoh_receive_frame {
    atomic_uint sequence;
    bool valid;
    uint32_t key_length;
    uint32_t payload_length;
    uint8_t key[AXOLOTY_ZENOH_MAX_KEY_BYTES];
    uint8_t payload[AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES];
};

struct axoloty_zenoh_session {
    z_owned_session_t zenoh_session;
    z_owned_subscriber_t zenoh_subscriber;
    bool open;
    bool subscribed;
    // Callback invocations claim distinct ring cells atomically; poll() is the
    // sole consumer. Per-cell release/acquire sequence publication permits
    // concurrent callbacks without locks or borrowed memory escaping.
    atomic_uint receive_enqueue_position;
    atomic_uint receive_dequeue_position;
    atomic_uint dropped_frames;
    atomic_uint oversized_frames;
    atomic_uint pending_full_results;
    atomic_uint pending_oversized_results;
    atomic_uint active_callbacks;
    atomic_bool callback_enabled;
    atomic_uint subscriber_generation;
    struct axoloty_zenoh_receive_frame receive_queue[AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY];
};

static struct axoloty_zenoh_session g_sessions[AXOLOTY_ZENOH_MAX_SESSIONS];

_Static_assert(AXOLOTY_ZENOH_MAX_SESSIONS == 4,
               "callback slot tokens reserve exactly 2 bits for four session slots");

static bool axoloty_zenoh_consume_pending_result(atomic_uint *pending) {
    unsigned count = atomic_load_explicit(pending, memory_order_acquire);
    while (count != 0) {
        if (atomic_compare_exchange_weak_explicit(pending,
                                                  &count,
                                                  count - 1,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
            return true;
        }
    }
    return false;
}

// Four registry slots use two low token bits. The remaining pointer-width
// bits carry a generation so late callbacks cannot write into a reused slot.
static unsigned axoloty_zenoh_advance_subscriber_generation(struct axoloty_zenoh_session *slot) {
    unsigned generation = (atomic_load_explicit(&slot->subscriber_generation, memory_order_relaxed) + 1) &
                          UINT32_C(0x3FFFFFFF);
    atomic_store_explicit(&slot->subscriber_generation, generation, memory_order_release);
    return generation;
}

static void axoloty_zenoh_reset_receive_queue(struct axoloty_zenoh_session *slot) {
    atomic_store_explicit(&slot->receive_enqueue_position, 0, memory_order_relaxed);
    atomic_store_explicit(&slot->receive_dequeue_position, 0, memory_order_relaxed);
    for (unsigned index = 0; index < AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY; index++) {
        slot->receive_queue[index].valid = false;
        atomic_store_explicit(&slot->receive_queue[index].sequence, index, memory_order_relaxed);
    }
    atomic_store_explicit(&slot->pending_full_results, 0, memory_order_relaxed);
    atomic_store_explicit(&slot->pending_oversized_results, 0, memory_order_relaxed);
}

static void axoloty_zenoh_reset_receive_counters(struct axoloty_zenoh_session *slot) {
    atomic_store_explicit(&slot->dropped_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&slot->oversized_frames, 0, memory_order_relaxed);
}

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
    axoloty_zenoh_reset_receive_queue(slot);
    axoloty_zenoh_reset_receive_counters(slot);
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

    if (slot->subscribed) {
        (void)axoloty_zenoh_unsubscribe(session);
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

static void axoloty_zenoh_receive_sample(z_loaned_sample_t *sample, void *context) {
    uintptr_t token = (uintptr_t)context;
    unsigned slot_index = (unsigned)(token & (AXOLOTY_ZENOH_MAX_SESSIONS - 1));
    unsigned generation = (unsigned)(token >> 2);
    struct axoloty_zenoh_session *slot = &g_sessions[slot_index];
    atomic_fetch_add_explicit(&slot->active_callbacks, 1, memory_order_acquire);
    if (!atomic_load_explicit(&slot->callback_enabled, memory_order_acquire) ||
        atomic_load_explicit(&slot->subscriber_generation, memory_order_acquire) != generation) {
        atomic_fetch_sub_explicit(&slot->active_callbacks, 1, memory_order_release);
        return;
    }
    const struct z_loaned_keyexpr_t *sample_key = z_sample_keyexpr(sample);
    z_view_string_t key_view;
    z_keyexpr_as_view_string(sample_key, &key_view);
    const struct z_loaned_string_t *key_string = z_view_string_loan(&key_view);
    size_t key_length = z_string_len(key_string);
    const struct z_loaned_bytes_t *sample_payload = z_sample_payload(sample);
    size_t payload_length = z_bytes_len(sample_payload);

    if (key_length == 0 || key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES ||
        payload_length > AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES) {
        atomic_fetch_add_explicit(&slot->pending_oversized_results, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&slot->oversized_frames, 1, memory_order_release);
        goto callback_done;
    }

    unsigned position = atomic_load_explicit(&slot->receive_enqueue_position, memory_order_relaxed);
    struct axoloty_zenoh_receive_frame *frame;
    for (;;) {
        frame = &slot->receive_queue[position % AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY];
        unsigned sequence = atomic_load_explicit(&frame->sequence, memory_order_acquire);
        int32_t difference = (int32_t)(sequence - position);
        if (difference == 0) {
            if (atomic_compare_exchange_weak_explicit(&slot->receive_enqueue_position,
                                                      &position,
                                                      position + 1,
                                                      memory_order_relaxed,
                                                      memory_order_relaxed)) {
                break;
            }
        } else if (difference < 0) {
            atomic_fetch_add_explicit(&slot->pending_full_results, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&slot->dropped_frames, 1, memory_order_release);
            goto callback_done;
        } else {
            position = atomic_load_explicit(&slot->receive_enqueue_position, memory_order_relaxed);
        }
    }
    memcpy(frame->key, z_string_data(key_string), key_length);
    struct z_bytes_reader_t reader = z_bytes_get_reader(sample_payload);
    size_t copied = z_bytes_reader_read(&reader, frame->payload, payload_length);
    if (copied != payload_length) {
        // A malformed/inconsistent sample is treated as oversized and never
        // published as a partial frame. Publish an invalid cell so producers
        // and the consumer can advance past this reserved position.
        frame->valid = false;
        atomic_fetch_add_explicit(&slot->pending_oversized_results, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&slot->oversized_frames, 1, memory_order_release);
        atomic_store_explicit(&frame->sequence, position + 1, memory_order_release);
        goto callback_done;
    }
    frame->valid = true;
    frame->key_length = (uint32_t)key_length;
    frame->payload_length = (uint32_t)payload_length;
    atomic_store_explicit(&frame->sequence, position + 1, memory_order_release);
callback_done:
    atomic_fetch_sub_explicit(&slot->active_callbacks, 1, memory_order_release);
}

axoloty_zenoh_result_t axoloty_zenoh_subscribe(const axoloty_zenoh_session_t *session,
                                               const uint8_t *key,
                                               uint32_t key_length) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL || key == NULL || key_length == 0 ||
        key_length > AXOLOTY_ZENOH_MAX_KEY_BYTES) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!slot->open) {
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    if (slot->subscribed) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    for (uint32_t index = 0; index < key_length; index++) {
        if (key[index] == 0) {
            return AXOLOTY_ZENOH_INVALID_ARGUMENT;
        }
    }
    if (z_keyexpr_is_canon((const char *)key, key_length) != Z_OK) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }

    z_owned_keyexpr_t key_expr;
    if (z_keyexpr_from_substr(&key_expr, (const char *)key, key_length) != Z_OK) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    axoloty_zenoh_reset_receive_queue(slot);
    unsigned slot_index = 0;
    while (slot != &g_sessions[slot_index]) {
        slot_index++;
    }
    unsigned generation = axoloty_zenoh_advance_subscriber_generation(slot);
    uintptr_t callback_token = ((uintptr_t)generation << 2) | slot_index;
    z_owned_closure_sample_t callback;
    z_closure_sample(&callback, axoloty_zenoh_receive_sample, NULL, (void *)callback_token);
    z_subscriber_options_t options;
    z_subscriber_options_default(&options);
    atomic_store_explicit(&slot->callback_enabled, true, memory_order_release);
    z_result_t result = z_declare_subscriber(
        z_session_loan(&slot->zenoh_session),
        &slot->zenoh_subscriber,
        z_keyexpr_loan(&key_expr),
        z_closure_sample_move(&callback),
        &options
    );
    z_keyexpr_drop(z_keyexpr_move(&key_expr));
    if (result != Z_OK) {
        atomic_store_explicit(&slot->callback_enabled, false, memory_order_release);
        (void)axoloty_zenoh_advance_subscriber_generation(slot);
        return AXOLOTY_ZENOH_TRANSPORT_ERROR;
    }
    axoloty_zenoh_reset_receive_counters(slot);
    slot->subscribed = true;
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_unsubscribe(const axoloty_zenoh_session_t *session) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!slot->open) {
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    if (!slot->subscribed) {
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    atomic_store_explicit(&slot->callback_enabled, false, memory_order_release);
    (void)axoloty_zenoh_advance_subscriber_generation(slot);
    z_subscriber_drop(z_subscriber_move(&slot->zenoh_subscriber));
    // Dropping the subscriber prevents new callback invocations. Drain any
    // callback that entered before it was disabled before resetting/reusing
    // the session's fixed queue storage.
    while (atomic_load_explicit(&slot->active_callbacks, memory_order_acquire) != 0) {
    }
    slot->subscribed = false;
    axoloty_zenoh_reset_receive_queue(slot);
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_poll(const axoloty_zenoh_session_t *session,
                                          uint8_t *key,
                                          uint32_t key_capacity,
                                          uint32_t *out_key_length,
                                          uint8_t *payload,
                                          uint32_t payload_capacity,
                                          uint32_t *out_payload_length) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL || out_key_length == NULL || out_payload_length == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    *out_key_length = 0;
    *out_payload_length = 0;
    if (!slot->open) {
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    for (;;) {
        unsigned position = atomic_load_explicit(&slot->receive_dequeue_position, memory_order_relaxed);
        struct axoloty_zenoh_receive_frame *frame =
            &slot->receive_queue[position % AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY];
        unsigned sequence = atomic_load_explicit(&frame->sequence, memory_order_acquire);
        if (sequence != position + 1) {
            // Report asynchronous admission failures after already-published
            // frames. If both kinds accumulated, full-queue notifications are
            // returned first; each notification is returned exactly once.
            if (axoloty_zenoh_consume_pending_result(&slot->pending_full_results)) {
                return AXOLOTY_ZENOH_QUEUE_FULL;
            }
            if (axoloty_zenoh_consume_pending_result(&slot->pending_oversized_results)) {
                return AXOLOTY_ZENOH_FRAME_TOO_LARGE;
            }
            return AXOLOTY_ZENOH_QUEUE_EMPTY;
        }
        if (!frame->valid) {
            atomic_store_explicit(&frame->sequence,
                                  position + AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY,
                                  memory_order_release);
            atomic_store_explicit(&slot->receive_dequeue_position, position + 1, memory_order_relaxed);
            continue;
        }
        if ((key == NULL && frame->key_length != 0) ||
            (payload == NULL && frame->payload_length != 0) ||
            key_capacity < frame->key_length || payload_capacity < frame->payload_length) {
            return AXOLOTY_ZENOH_INVALID_ARGUMENT;
        }
        if (frame->key_length > 0) {
            memcpy(key, frame->key, frame->key_length);
        }
        if (frame->payload_length > 0) {
            memcpy(payload, frame->payload, frame->payload_length);
        }
        *out_key_length = frame->key_length;
        *out_payload_length = frame->payload_length;
        atomic_store_explicit(&frame->sequence,
                              position + AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY,
                              memory_order_release);
        atomic_store_explicit(&slot->receive_dequeue_position, position + 1, memory_order_relaxed);
        return AXOLOTY_ZENOH_OK;
    }
}

axoloty_zenoh_result_t axoloty_zenoh_queue_depth(const axoloty_zenoh_session_t *session,
                                                 uint32_t *out_depth) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL || out_depth == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!slot->open) {
        *out_depth = 0;
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    unsigned tail = atomic_load_explicit(&slot->receive_dequeue_position, memory_order_acquire);
    unsigned head = atomic_load_explicit(&slot->receive_enqueue_position, memory_order_acquire);
    unsigned reserved = head - tail;
    if (reserved > AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY) {
        reserved = AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY;
    }
    *out_depth = 0;
    for (unsigned offset = 0; offset < reserved; offset++) {
        struct axoloty_zenoh_receive_frame *frame =
            &slot->receive_queue[(tail + offset) % AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY];
        if (atomic_load_explicit(&frame->sequence, memory_order_acquire) != tail + offset + 1) {
            break;
        }
        if (frame->valid) {
            (*out_depth)++;
        }
    }
    return AXOLOTY_ZENOH_OK;
}

static axoloty_zenoh_result_t axoloty_zenoh_counter(const axoloty_zenoh_session_t *session,
                                                    uint32_t *out_count,
                                                    const atomic_uint *counter) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    if (slot == NULL || out_count == NULL) {
        return AXOLOTY_ZENOH_INVALID_ARGUMENT;
    }
    if (!slot->open) {
        *out_count = 0;
        return AXOLOTY_ZENOH_NOT_OPEN;
    }
    *out_count = atomic_load_explicit(counter, memory_order_acquire);
    return AXOLOTY_ZENOH_OK;
}

axoloty_zenoh_result_t axoloty_zenoh_dropped_frame_count(const axoloty_zenoh_session_t *session,
                                                         uint32_t *out_count) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    return axoloty_zenoh_counter(session, out_count, slot == NULL ? NULL : &slot->dropped_frames);
}

axoloty_zenoh_result_t axoloty_zenoh_oversized_frame_count(const axoloty_zenoh_session_t *session,
                                                            uint32_t *out_count) {
    struct axoloty_zenoh_session *slot = axoloty_zenoh_slot(session);
    return axoloty_zenoh_counter(session, out_count, slot == NULL ? NULL : &slot->oversized_frames);
}
