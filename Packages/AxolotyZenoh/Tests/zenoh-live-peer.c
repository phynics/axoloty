// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <zenoh.h>

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct received_state {
    atomic_bool received;
};

static void on_sample(z_loaned_sample_t *sample, void *context) {
    struct received_state *state = context;
    const struct z_loaned_bytes_t *payload = z_sample_payload(sample);
    char bytes[2049];
    size_t length = z_bytes_len(payload);
    if (length >= sizeof(bytes)) return;
    struct z_bytes_reader_t reader = z_bytes_get_reader(payload);
    if (z_bytes_reader_read(&reader, (uint8_t *)bytes, length) != length) return;
    bytes[length] = '\0';
    printf("RECEIVED %s\n", bytes);
    fflush(stdout);
    atomic_store_explicit(&state->received, true, memory_order_release);
}

static int open_client(z_owned_session_t *session, const char *endpoint) {
    z_owned_config_t config;
    if (z_config_default(&config) != Z_OK) return 1;
    char endpoints[256];
    if (snprintf(endpoints, sizeof(endpoints), "[\"%s\"]", endpoint) >= (int)sizeof(endpoints)) return 1;
    if (zc_config_insert_json5(z_config_loan_mut(&config), Z_CONFIG_MODE_KEY, "\"client\"") != Z_OK ||
        zc_config_insert_json5(z_config_loan_mut(&config), Z_CONFIG_CONNECT_KEY, endpoints) != Z_OK) {
        z_config_drop(z_config_move(&config));
        return 1;
    }
    z_open_options_t options;
    z_open_options_default(&options);
    return z_open(session, z_config_move(&config), &options) == Z_OK ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc != 4 || (strcmp(argv[1], "publish") != 0 && strcmp(argv[1], "subscribe") != 0)) {
        fprintf(stderr, "usage: zenoh-live-peer publish|subscribe ENDPOINT KEY\n");
        return 64;
    }
    z_owned_session_t session;
    if (open_client(&session, argv[2]) != 0) return 2;
    z_owned_keyexpr_t key;
    if (z_keyexpr_from_str(&key, argv[3]) != Z_OK) return 2;

    int status = 0;
    if (strcmp(argv[1], "publish") == 0) {
        static const char message[] = "independent-c-peer";
        z_owned_bytes_t payload;
        if (z_bytes_copy_from_buf(&payload, message, sizeof(message) - 1) != Z_OK) {
            status = 3;
        } else {
            z_put_options_t options;
            z_put_options_default(&options);
            status = z_put(z_session_loan(&session), z_keyexpr_loan(&key), z_bytes_move(&payload), &options) == Z_OK ? 0 : 3;
            if (status == 0) puts("PUBLISHED");
        }
    } else {
        struct received_state state = {0};
        atomic_init(&state.received, false);
        z_owned_closure_sample_t callback;
        z_closure_sample(&callback, on_sample, NULL, &state);
        z_subscriber_options_t options;
        z_subscriber_options_default(&options);
        z_owned_subscriber_t subscriber;
        if (z_declare_subscriber(z_session_loan(&session), &subscriber, z_keyexpr_loan(&key),
                                 z_closure_sample_move(&callback), &options) != Z_OK) {
            status = 4;
        } else {
            puts("READY");
            fflush(stdout);
            const struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
            for (unsigned tick = 0; tick < 1500 && !atomic_load_explicit(&state.received, memory_order_acquire); tick++) {
                nanosleep(&pause, NULL);
            }
            status = atomic_load_explicit(&state.received, memory_order_acquire) ? 0 : 5;
            z_subscriber_drop(z_subscriber_move(&subscriber));
        }
    }
    z_keyexpr_drop(z_keyexpr_move(&key));
    z_close_options_t close_options;
    z_close_options_default(&close_options);
    (void)z_close(z_session_loan_mut(&session), &close_options);
    z_session_drop(z_session_move(&session));
    return status;
}
