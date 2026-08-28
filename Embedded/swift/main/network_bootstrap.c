// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Deliberately synchronous Wi-Fi/MQTT test façade. ESP-MQTT callbacks only
// inspect or copy bounded data while they execute; no callback pointer escapes.

#include "esp_event.h"
#include "esp_mac.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "mqtt_client.h"
#include "nvs_flash.h"
#include "runtime_identity.h"
#include "embedded_shared_flags.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#if __has_include("axoloty_network_config.h")
#include "axoloty_network_config.h"
#else
#define AXOLOTY_NETWORK_CONFIGURED 0
static const char axoloty_runtime_identity[] = "";
#endif

#define WIFI_BIT (1U << 0)
#define IP_BIT (1U << 1)
#define WIFI_FAIL_BIT (1U << 2)
#define NETWORK_MAX_TOPIC 257
#define NETWORK_MAX_PAYLOAD 2049
#define AGENT_CONNECTED_BIT (1U << 8)
#define AGENT_SUBSCRIBED_BIT (1U << 9)
#define AGENT_ADVERTISE_BIT (1U << 10)
#define AGENT_DISCOVER_BIT (1U << 11)
#define AGENT_RESOLVE_BIT (1U << 12)
#define AGENT_DEADVERTISE_BIT (1U << 13)

extern int32_t axoloty_static_agent_prepare(
    int32_t role, int32_t kind,
    uint8_t *topic, int32_t topic_capacity,
    uint8_t *payload, int32_t payload_capacity,
    int32_t *topic_length, int32_t *payload_length);
extern int32_t axoloty_static_agent_receive(
    int32_t role,
    const uint8_t *topic, int32_t topic_length,
    const uint8_t *payload, int32_t payload_length,
    uint8_t *output_topic, int32_t output_topic_capacity,
    uint8_t *output_payload, int32_t output_payload_capacity,
    int32_t *output_topic_length, int32_t *output_payload_length);
extern int32_t axoloty_static_agent_expire(int32_t role);
extern int32_t axoloty_static_agent_copy_actor_route(
    int32_t role, uint8_t *route, int32_t route_capacity);
unsigned int axoloty_network_cleanup(void);

static EventGroupHandle_t network_events;
static esp_mqtt_client_handle_t mqtt_client;
static AxolotyEmbeddedSharedFlags network_flags;
static char network_topic[NETWORK_MAX_TOPIC];
static char network_subscription_topic[NETWORK_MAX_TOPIC];
static char network_payload[NETWORK_MAX_PAYLOAD];
static char network_will_topic[NETWORK_MAX_TOPIC];
static char network_will_payload[NETWORK_MAX_PAYLOAD];
static char network_uri[128];
static char network_client_id[64];
static size_t network_payload_length;
static int network_will_payload_length;
static int network_will_configured;
static esp_netif_t *network_netif;
static int network_event_loop_ready;
static int network_wifi_initialized;
static int network_wifi_started;
static int network_wifi_handler_registered;
static int network_ip_handler_registered;
static unsigned int network_agent_role;
static unsigned int network_agent_scenario;
static uint32_t network_overall_start;
static unsigned int network_overall_deadline_ms;
static uint8_t agent_output_topic[NETWORK_MAX_TOPIC];
static uint8_t agent_output_payload[NETWORK_MAX_PAYLOAD];
static uint8_t agent_will_topic[NETWORK_MAX_TOPIC];
static uint8_t agent_will_payload[NETWORK_MAX_PAYLOAD];
static uint8_t agent_actor_route[NETWORK_MAX_TOPIC];
static int32_t agent_actor_route_length;

static unsigned network_mqtt_bits_load(void) {
    return axoloty_atomic_uint_load(&network_flags.mqtt_bits);
}

static void network_mqtt_bits_store(unsigned bits) {
    axoloty_atomic_uint_store(&network_flags.mqtt_bits, bits);
}

static void network_mqtt_bits_set(unsigned bits) {
    axoloty_atomic_uint_fetch_or(&network_flags.mqtt_bits, bits);
}

static void network_mqtt_bits_clear(unsigned bits) {
    axoloty_atomic_uint_fetch_and(&network_flags.mqtt_bits, ~bits);
}

static unsigned network_connect_count_load(void) {
    return axoloty_atomic_uint_load(&network_flags.network_connect_count);
}

static unsigned agent_connect_count_load(void) {
    return axoloty_atomic_uint_load(&network_flags.agent_connect_count);
}

static unsigned wifi_retry_count_load(void) {
    return axoloty_atomic_uint_load(&network_flags.wifi_retry_count);
}

static int network_forced_wifi_disconnect_load(void) {
    return axoloty_atomic_int_load(&network_flags.forced_wifi_disconnect);
}

static int network_read_station_mac(uint8_t mac[6], void *context) {
    (void)context;
    return esp_read_mac(mac, ESP_MAC_WIFI_STA) == ESP_OK;
}

static int network_prepare_client_id(void) {
    return axoloty_runtime_identity_prepare(
        axoloty_runtime_identity, network_read_station_mac, NULL,
        network_client_id, sizeof(network_client_id));
}
static void network_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == IP_EVENT_STA_GOT_IP) {
        axoloty_atomic_uint_store(&network_flags.wifi_retry_count, 0);
        xEventGroupSetBits(network_events, IP_BIT);
    }
}

static void network_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == WIFI_EVENT_STA_START) esp_wifi_connect();
    else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        if (network_forced_wifi_disconnect_load()) {
            xEventGroupSetBits(network_events, WIFI_FAIL_BIT);
        } else if (wifi_retry_count_load() < 5U) {
            axoloty_atomic_uint_fetch_add(&network_flags.wifi_retry_count, 1U);
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(network_events, WIFI_FAIL_BIT);
        }
    }
}

static void network_mqtt_event(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    (void)handler_args; (void)base;
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;
    if (event_id == MQTT_EVENT_CONNECTED) {
        if (network_agent_role) {
            unsigned connect_count = axoloty_atomic_uint_fetch_add(
                &network_flags.agent_connect_count, 1U) + 1U;
            network_mqtt_bits_set(AGENT_CONNECTED_BIT);
            if (connect_count > 1U) {
                esp_mqtt_client_subscribe(mqtt_client, "coaty/3/axoloty-embedded/#", 0);
                if (agent_actor_route_length > 0) {
                    esp_mqtt_client_subscribe(
                        mqtt_client, (const char *)agent_actor_route, 0);
                }
            }
        } else {
            unsigned connect_count = axoloty_atomic_uint_fetch_add(
                &network_flags.network_connect_count, 1U) + 1U;
            network_mqtt_bits_set(4U);
            if (connect_count > 1U && network_subscription_topic[0] != 0) {
                esp_mqtt_client_subscribe(mqtt_client, network_subscription_topic, 0);
            }
        }
    }
    else if (event_id == MQTT_EVENT_DISCONNECTED && network_agent_role) {
        network_mqtt_bits_clear(AGENT_CONNECTED_BIT | AGENT_SUBSCRIBED_BIT);
    }
    else if (event_id == MQTT_EVENT_DISCONNECTED) network_mqtt_bits_clear(4U | 8U);
    else if (event_id == MQTT_EVENT_SUBSCRIBED) network_mqtt_bits_set(network_agent_role ? AGENT_SUBSCRIBED_BIT : 8U);
    else if (event_id == MQTT_EVENT_PUBLISHED) network_mqtt_bits_set(16U);
    else if (event_id == MQTT_EVENT_DATA && network_agent_role) {
        int valid = event && event->topic_len >= 0 && event->topic_len < NETWORK_MAX_TOPIC &&
            event->data_len >= 0 && event->data_len < NETWORK_MAX_PAYLOAD &&
            event->total_data_len >= 0 && event->total_data_len < NETWORK_MAX_PAYLOAD &&
            event->current_data_offset >= 0 &&
            event->current_data_offset <= event->total_data_len &&
            event->data_len <= event->total_data_len - event->current_data_offset &&
            event->data;
        // The static endpoint profile has no reassembly buffer. A fragmented
        // PUBLISH is rejected at the transport boundary instead of retaining
        // partial untrusted data or allocating a continuation buffer.
        valid = valid && event->topic && event->topic_len > 0 &&
            event->current_data_offset == 0 && event->data_len == event->total_data_len;
        if (valid) {
            int32_t output_topic_length = 0;
            int32_t output_payload_length = 0;
            int32_t action = axoloty_static_agent_receive(
                (int32_t)network_agent_role,
                (const uint8_t *)event->topic, event->topic_len,
                (const uint8_t *)event->data, event->data_len,
                agent_output_topic, sizeof(agent_output_topic),
                agent_output_payload, sizeof(agent_output_payload),
                &output_topic_length, &output_payload_length);
            if (action == 1) {
                if (network_agent_role == 1U) network_mqtt_bits_set(AGENT_DISCOVER_BIT);
                else network_mqtt_bits_set(AGENT_ADVERTISE_BIT);
                if (network_agent_scenario == 1U && network_agent_role == 2U) {
                    esp_mqtt_client_publish(
                        mqtt_client, "axoloty/test/agent-observed/B", "advertise", 9, 0, 0);
                    return;
                }
                if (output_topic_length > 0 && output_topic_length < (int32_t)sizeof(agent_output_topic)) {
                    agent_output_topic[output_topic_length] = 0;
                }
                if (output_topic_length > 0 && output_topic_length < (int32_t)sizeof(agent_output_topic) &&
                    esp_mqtt_client_publish(
                        mqtt_client, (const char *)agent_output_topic,
                        (const char *)agent_output_payload, output_payload_length, 0, 0) >= 0) {
                    if (network_agent_role == 1U) network_mqtt_bits_set(AGENT_RESOLVE_BIT);
                    else network_mqtt_bits_set(AGENT_DISCOVER_BIT);
                }
            } else if (action == 2 && network_agent_role == 2U) {
                network_mqtt_bits_set(AGENT_RESOLVE_BIT);
            } else if (action == 3 && network_agent_role == 2U) {
                if (network_agent_scenario != 1U ||
                    (network_mqtt_bits_load() & AGENT_ADVERTISE_BIT)) {
                    network_mqtt_bits_set(AGENT_DEADVERTISE_BIT);
                }
            } else if (action == 4) {
                int32_t route_length = axoloty_static_agent_copy_actor_route(
                    (int32_t)network_agent_role, agent_actor_route,
                    sizeof(agent_actor_route) - 1);
                if (route_length > 0 && route_length < (int32_t)sizeof(agent_actor_route)) {
                    agent_actor_route[route_length] = 0;
                    agent_actor_route_length = route_length;
                    esp_mqtt_client_subscribe(
                        mqtt_client, (const char *)agent_actor_route, 0);
                }
            } else if (action == 5 && agent_actor_route_length > 0) {
                esp_mqtt_client_unsubscribe(
                    mqtt_client, (const char *)agent_actor_route);
                agent_actor_route_length = 0;
            }
        }
    } else if (event_id == MQTT_EVENT_DATA && event && event->topic && event->data &&
              event->topic_len >= 0 && event->topic_len < NETWORK_MAX_TOPIC &&
              event->data_len >= 0 && event->data_len < NETWORK_MAX_PAYLOAD &&
              event->topic_len == (int)strlen(network_topic) &&
             event->data_len == (int)network_payload_length &&
             memcmp(event->topic, network_topic, event->topic_len) == 0 &&
             memcmp(event->data, network_payload, event->data_len) == 0) {
        network_mqtt_bits_set(32U);
    }
}

static int network_deadline(uint32_t start, uint32_t timeout) {
    return (uint32_t)(esp_timer_get_time() / 1000ULL) - start < timeout;
}

static TickType_t network_wait_ticks(uint32_t start, uint32_t timeout, uint32_t maximum_wait_ms) {
    uint32_t elapsed = (uint32_t)(esp_timer_get_time() / 1000ULL) - start;
    if (elapsed >= timeout) return 0;
    uint32_t remaining = timeout - elapsed;
    return pdMS_TO_TICKS(remaining < maximum_wait_ms ? remaining : maximum_wait_ms);
}

unsigned int axoloty_network_prepare(unsigned int overall_deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)overall_deadline_ms;
    return 0;
#else
    const uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    network_overall_start = start;
    network_overall_deadline_ms = overall_deadline_ms;
    network_event_loop_ready = 0;
    network_wifi_initialized = 0;
    network_wifi_started = 0;
    network_wifi_handler_registered = 0;
    network_ip_handler_registered = 0;
    axoloty_atomic_uint_store(&network_flags.wifi_retry_count, 0);
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        if (nvs_flash_erase() != ESP_OK) return 0;
        err = nvs_flash_init();
    }
    if (err != ESP_OK || esp_netif_init() != ESP_OK || esp_event_loop_create_default() != ESP_OK) return 0;
    network_event_loop_ready = 1;
    network_events = xEventGroupCreate();
    if (!network_events) goto network_prepare_failed;
    network_netif = esp_netif_create_default_wifi_sta();
    if (!network_netif) goto network_prepare_failed;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (esp_wifi_init(&init) != ESP_OK) goto network_prepare_failed;
    network_wifi_initialized = 1;
    if (esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event, NULL) != ESP_OK) {
        goto network_prepare_failed;
    }
    network_wifi_handler_registered = 1;
    if (esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event, NULL) != ESP_OK) {
        goto network_prepare_failed;
    }
    network_ip_handler_registered = 1;
    wifi_config_t wifi = { 0 };
    memcpy(wifi.sta.ssid, axoloty_wifi_ssid, axoloty_wifi_ssid_length);
    memcpy(wifi.sta.password, axoloty_wifi_password, axoloty_wifi_password_length);
    wifi.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK || esp_wifi_set_config(WIFI_IF_STA, &wifi) != ESP_OK ||
        esp_wifi_start() != ESP_OK) goto network_prepare_failed;
    network_wifi_started = 1;
    EventBits_t bits = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT | IP_BIT, pdFALSE, pdFALSE,
        network_wait_ticks(start, overall_deadline_ms, 30000));
    if ((bits & IP_BIT) == 0 || !network_deadline(start, overall_deadline_ms)) goto network_prepare_failed;
    uint32_t stamp = (uint32_t)(esp_timer_get_time() / 1000ULL);
    int topic_length = snprintf(network_topic, sizeof(network_topic), "axoloty/network/%u", (unsigned)stamp);
    int payload_length = snprintf(network_payload, sizeof(network_payload), "axoloty-network-%u", (unsigned)stamp);
    int uri_length = snprintf(network_uri, sizeof(network_uri), "mqtt://%s:%u", axoloty_mqtt_host,
                               (unsigned)axoloty_mqtt_port);
    if (topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC || payload_length <= 0 ||
        payload_length >= NETWORK_MAX_PAYLOAD || uri_length <= 0 || uri_length >= (int)sizeof(network_uri)) {
        goto network_prepare_failed;
    }
    network_payload_length = (size_t)payload_length;
    return 3U;
network_prepare_failed:
    axoloty_network_cleanup();
    return 0;
#endif
}

int axoloty_network_copy_topic(unsigned char *buffer, int capacity) {
    int length = (int)strlen(network_topic);
    if (!buffer || capacity <= length) return 0;
    memcpy(buffer, network_topic, (size_t)length);
    return length;
}

int axoloty_network_copy_payload(unsigned char *buffer, int capacity) {
    int length = (int)network_payload_length;
    if (!buffer || capacity < length) return 0;
    memcpy(buffer, network_payload, (size_t)length);
    return length;
}

int axoloty_mqtt_configure_last_will(const unsigned char *topic, int topic_length,
                                     const unsigned char *payload, int payload_length) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)topic; (void)topic_length; (void)payload; (void)payload_length;
    return 0;
#else
    if (!topic || !payload || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC ||
        payload_length < 0 || payload_length >= NETWORK_MAX_PAYLOAD || mqtt_client) return 0;
    memcpy(network_will_topic, topic, (size_t)topic_length);
    network_will_topic[topic_length] = 0;
    memcpy(network_will_payload, payload, (size_t)payload_length);
    network_will_payload[payload_length] = 0;
    network_will_payload_length = payload_length;
    network_will_configured = 1;
    return 1;
#endif
}

int axoloty_mqtt_connect_wait(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    network_mqtt_bits_store(0);
    axoloty_atomic_uint_store(&network_flags.network_connect_count, 0);
    if (!network_prepare_client_id()) return 0;
    esp_mqtt_client_config_t config = { 0 };
    config.broker.address.uri = network_uri;
    config.credentials.client_id = network_client_id;
    if (network_will_configured) {
        config.session.last_will.topic = network_will_topic;
        config.session.last_will.msg = network_will_payload;
        config.session.last_will.msg_len = network_will_payload_length;
        config.session.last_will.qos = 0;
        config.session.last_will.retain = 0;
    }
    mqtt_client = esp_mqtt_client_init(&config);
    if (!mqtt_client) return 0;
    if (esp_mqtt_client_register_event(mqtt_client, ESP_EVENT_ANY_ID, network_mqtt_event, NULL) != ESP_OK ||
        esp_mqtt_client_start(mqtt_client) != ESP_OK) {
        esp_mqtt_client_destroy(mqtt_client);
        mqtt_client = NULL;
        return 0;
    }
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           !(network_mqtt_bits_load() & 4U)) vTaskDelay(pdMS_TO_TICKS(20));
    if (network_mqtt_bits_load() & 4U) return 1;
    esp_mqtt_client_stop(mqtt_client);
    esp_mqtt_client_destroy(mqtt_client);
    mqtt_client = NULL;
    return 0;
#endif
}

int axoloty_mqtt_subscribe_wait(const unsigned char *topic, int topic_length,
                                unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)topic; (void)topic_length; (void)deadline_ms;
    return 0;
#else
    if (!mqtt_client || !topic || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC) return 0;
    memcpy(network_subscription_topic, topic, (size_t)topic_length);
    network_subscription_topic[topic_length] = 0;
    if (esp_mqtt_client_subscribe(mqtt_client, network_subscription_topic, 0) < 0) return 0;
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           !(network_mqtt_bits_load() & 8U)) vTaskDelay(pdMS_TO_TICKS(20));
    return (network_mqtt_bits_load() & 8U) != 0;
#endif
}

int axoloty_mqtt_publish(const unsigned char *topic, int topic_length,
                        const unsigned char *payload, int payload_length) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)topic; (void)topic_length; (void)payload; (void)payload_length;
    return 0;
#else
    if (!mqtt_client || !topic || !payload || topic_length <= 0 || topic_length >= NETWORK_MAX_TOPIC ||
        payload_length < 0 || payload_length >= NETWORK_MAX_PAYLOAD) return 0;
    memcpy(network_topic, topic, (size_t)topic_length);
    network_topic[topic_length] = 0;
    memcpy(network_payload, payload, (size_t)payload_length);
    network_payload[payload_length] = 0;
    network_payload_length = (size_t)payload_length;
    return esp_mqtt_client_publish(mqtt_client, network_topic, network_payload, payload_length, 0, 0) >= 0;
#endif
}

int axoloty_mqtt_wait_loopback(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           !(network_mqtt_bits_load() & 32U)) vTaskDelay(pdMS_TO_TICKS(20));
    return (network_mqtt_bits_load() & 32U) != 0;
#endif
}

int axoloty_mqtt_reconnect_wait(unsigned int deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)deadline_ms;
    return 0;
#else
    if (!mqtt_client || network_subscription_topic[0] == 0) return 0;
    uint32_t start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    xEventGroupClearBits(network_events, WIFI_FAIL_BIT | IP_BIT);
    network_mqtt_bits_clear(4U | 8U);
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 1);
    if (esp_wifi_disconnect() != ESP_OK) {
        axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
        return 0;
    }
    EventBits_t disconnected = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT, pdTRUE, pdFALSE,
        network_wait_ticks(start, deadline_ms, 5000));
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
    if (!(disconnected & WIFI_FAIL_BIT) || esp_wifi_connect() != ESP_OK) return 0;
    while (network_deadline(start, deadline_ms) &&
           network_deadline(network_overall_start, network_overall_deadline_ms) &&
           (!(network_mqtt_bits_load() & 4U) || !(network_mqtt_bits_load() & 8U))) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    return (network_mqtt_bits_load() & (4U | 8U)) == (4U | 8U) &&
        network_connect_count_load() > 1U;
#endif
}

int axoloty_mqtt_disconnect(void) {
    if (!mqtt_client) return 1;
    esp_err_t stop = esp_mqtt_client_stop(mqtt_client);
    esp_err_t destroy = esp_mqtt_client_destroy(mqtt_client);
    mqtt_client = NULL;
    return stop == ESP_OK && destroy == ESP_OK;
}

unsigned int axoloty_network_cleanup(void) {
#if !AXOLOTY_NETWORK_CONFIGURED
    return 0;
#else
    if (network_wifi_handler_registered) {
        esp_event_handler_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event);
    }
    if (network_ip_handler_registered) {
        esp_event_handler_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event);
    }
    esp_err_t disconnect = !network_wifi_started || esp_wifi_disconnect() == ESP_OK ? ESP_OK : ESP_FAIL;
    esp_err_t stop = !network_wifi_started || esp_wifi_stop() == ESP_OK ? ESP_OK : ESP_FAIL;
    esp_err_t deinit = !network_wifi_initialized || esp_wifi_deinit() == ESP_OK ? ESP_OK : ESP_FAIL;
    if (network_netif) esp_netif_destroy_default_wifi(network_netif);
    network_netif = NULL;
    if (network_event_loop_ready) esp_event_loop_delete_default();
    if (network_events) vEventGroupDelete(network_events);
    network_events = NULL;
    network_event_loop_ready = 0;
    network_wifi_initialized = 0;
    network_wifi_started = 0;
    network_wifi_handler_registered = 0;
    network_ip_handler_registered = 0;
    network_subscription_topic[0] = 0;
    network_will_configured = 0;
    axoloty_atomic_uint_store(&network_flags.network_connect_count, 0);
    return disconnect == ESP_OK && stop == ESP_OK && deinit == ESP_OK;
#endif
}

int axoloty_network_configured(void) {
#if AXOLOTY_NETWORK_CONFIGURED
    return 1;
#else
    return 0;
#endif
}

unsigned int axoloty_network_role(void) {
#if AXOLOTY_NETWORK_CONFIGURED
    return axoloty_device_role;
#else
    return 0;
#endif
}

unsigned int axoloty_network_scenario(void) {
#if AXOLOTY_NETWORK_CONFIGURED
    return axoloty_agent_scenario;
#else
    return 0;
#endif
}

unsigned int axoloty_agent_test(unsigned int overall_deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)overall_deadline_ms;
    return 0;
#else
    if (axoloty_device_role != 1U && axoloty_device_role != 2U) return 0;
    esp_log_level_set("*", ESP_LOG_WARN);
    const uint32_t overall_start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    esp_netif_t *netif = NULL;
    int event_loop_ready = 0;
    int wifi_initialized = 0;
    int wifi_started = 0;
    int wifi_handler_registered = 0;
    int ip_handler_registered = 0;
    int mqtt_started = 0;
    axoloty_atomic_uint_store(&network_flags.wifi_retry_count, 0);
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
    unsigned int result = 0;
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        if (nvs_flash_erase() != ESP_OK) return 0;
        err = nvs_flash_init();
    }
    if (err != ESP_OK) return 0;
    if (esp_netif_init() != ESP_OK || esp_event_loop_create_default() != ESP_OK) return 0;
    event_loop_ready = 1;
    network_events = xEventGroupCreate();
    if (!network_events) goto agent_done;
    netif = esp_netif_create_default_wifi_sta();
    if (!netif) goto agent_done;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (esp_wifi_init(&init) != ESP_OK) goto agent_done;
    wifi_initialized = 1;
    if (esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event, NULL) != ESP_OK) goto agent_done;
    wifi_handler_registered = 1;
    if (esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event, NULL) != ESP_OK) goto agent_done;
    ip_handler_registered = 1;
    wifi_config_t wifi = { 0 };
    memcpy(wifi.sta.ssid, axoloty_wifi_ssid, axoloty_wifi_ssid_length);
    memcpy(wifi.sta.password, axoloty_wifi_password, axoloty_wifi_password_length);
    wifi.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK || esp_wifi_set_config(WIFI_IF_STA, &wifi) != ESP_OK ||
        esp_wifi_start() != ESP_OK) goto agent_done;
    wifi_started = 1;
    EventBits_t wifi_bits = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT | IP_BIT, pdFALSE, pdFALSE,
        network_wait_ticks(overall_start, overall_deadline_ms, 30000));
    if ((wifi_bits & IP_BIT) == 0 || !network_deadline(overall_start, overall_deadline_ms)) goto agent_done;
    result |= 1U | 2U;

    char uri[128];
    int uri_length = snprintf(uri, sizeof(uri), "mqtt://%s:%u", axoloty_mqtt_host, (unsigned)axoloty_mqtt_port);
    if (uri_length <= 0 || uri_length >= (int)sizeof(uri)) goto agent_done;
    int32_t will_topic_length = 0;
    int32_t will_payload_length = 0;
    int has_will = axoloty_device_role == 1U && axoloty_static_agent_prepare(
        1, 4, agent_will_topic, sizeof(agent_will_topic),
        agent_will_payload, sizeof(agent_will_payload),
        &will_topic_length, &will_payload_length) != 0;
    if (has_will && will_topic_length < (int32_t)sizeof(agent_will_topic)) {
        agent_will_topic[will_topic_length] = 0;
    } else {
        has_will = 0;
    }

    if (!network_prepare_client_id()) goto agent_done;
    esp_mqtt_client_config_t config = { 0 };
    config.broker.address.uri = uri;
    config.credentials.client_id = network_client_id;
    if (has_will) {
        config.session.last_will.topic = (const char *)agent_will_topic;
        config.session.last_will.msg = (const char *)agent_will_payload;
        config.session.last_will.msg_len = will_payload_length;
        config.session.last_will.qos = 0;
        config.session.last_will.retain = 0;
    }
    network_agent_role = axoloty_device_role;
    network_agent_scenario = axoloty_agent_scenario;
    axoloty_atomic_uint_store(&network_flags.agent_connect_count, 0);
    agent_actor_route_length = 0;
    network_mqtt_bits_store(0);
    mqtt_client = esp_mqtt_client_init(&config);
    if (!mqtt_client || esp_mqtt_client_register_event(mqtt_client, ESP_EVENT_ANY_ID, network_mqtt_event, NULL) != ESP_OK ||
        esp_mqtt_client_start(mqtt_client) != ESP_OK) goto agent_done;
    mqtt_started = 1;
    while (network_deadline(overall_start, overall_deadline_ms) &&
           !(network_mqtt_bits_load() & AGENT_CONNECTED_BIT)) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!(network_mqtt_bits_load() & AGENT_CONNECTED_BIT)) goto agent_done;
    result |= 4U;
    if (esp_mqtt_client_subscribe(mqtt_client, "coaty/3/axoloty-embedded/#", 0) < 0) goto agent_done;
    while (network_deadline(overall_start, overall_deadline_ms) &&
           !(network_mqtt_bits_load() & AGENT_SUBSCRIBED_BIT)) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!(network_mqtt_bits_load() & AGENT_SUBSCRIBED_BIT)) goto agent_done;
    result |= 8U;

    xEventGroupClearBits(network_events, WIFI_FAIL_BIT | IP_BIT);
    network_mqtt_bits_clear(AGENT_CONNECTED_BIT | AGENT_SUBSCRIBED_BIT);
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 1);
    if (esp_wifi_disconnect() != ESP_OK) goto agent_done;
    EventBits_t disconnected = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT, pdTRUE, pdFALSE, pdMS_TO_TICKS(5000));
    if (!(disconnected & WIFI_FAIL_BIT)) goto agent_done;
    vTaskDelay(pdMS_TO_TICKS(500));
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
    if (esp_wifi_connect() != ESP_OK) goto agent_done;
    while (network_deadline(overall_start, overall_deadline_ms) &&
           (!(network_mqtt_bits_load() & AGENT_CONNECTED_BIT) ||
            !(network_mqtt_bits_load() & AGENT_SUBSCRIBED_BIT))) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!(network_mqtt_bits_load() & AGENT_CONNECTED_BIT) ||
        !(network_mqtt_bits_load() & AGENT_SUBSCRIBED_BIT)) goto agent_done;
    result |= 512U;

    if (network_agent_scenario == 2U) {
        if (esp_mqtt_client_publish(
                mqtt_client, "axoloty/test/agent-ready/B", "ready", 5, 0, 0) < 0) goto agent_done;
        while (network_deadline(overall_start, overall_deadline_ms) &&
               (agent_connect_count_load() < 3U ||
                !(network_mqtt_bits_load() & AGENT_SUBSCRIBED_BIT))) {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        if (agent_connect_count_load() < 3U ||
            !(network_mqtt_bits_load() & AGENT_SUBSCRIBED_BIT)) goto agent_done;
        result |= 1024U;
    }

    if (network_agent_scenario == 1U && axoloty_device_role == 2U &&
        esp_mqtt_client_publish(
            mqtt_client, "axoloty/test/agent-ready/B", "ready", 5, 0, 0) < 0) {
        goto agent_done;
    }

    if (axoloty_device_role == 1U) {
        int32_t topic_length = 0;
        int32_t payload_length = 0;
        if (!axoloty_static_agent_prepare(
                1, 1, agent_output_topic, sizeof(agent_output_topic),
                agent_output_payload, sizeof(agent_output_payload),
                &topic_length, &payload_length) || topic_length >= (int32_t)sizeof(agent_output_topic)) goto agent_done;
        agent_output_topic[topic_length] = 0;
        if (network_agent_scenario == 1U) {
            while (network_deadline(overall_start, overall_deadline_ms)) {
                if (esp_mqtt_client_publish(
                        mqtt_client, (const char *)agent_output_topic,
                        (const char *)agent_output_payload, payload_length, 0, 0) >= 0) {
                    network_mqtt_bits_set(AGENT_ADVERTISE_BIT);
                }
                vTaskDelay(pdMS_TO_TICKS(1000));
            }
            goto agent_done;
        }
        while (network_deadline(overall_start, overall_deadline_ms) &&
               !(network_mqtt_bits_load() & AGENT_DISCOVER_BIT)) {
            if (esp_mqtt_client_publish(
                    mqtt_client, (const char *)agent_output_topic,
                    (const char *)agent_output_payload, payload_length, 0, 0) >= 0) {
                network_mqtt_bits_set(AGENT_ADVERTISE_BIT);
            }
            for (int wait = 0; wait < 100 &&
                 !(network_mqtt_bits_load() & AGENT_DISCOVER_BIT); ++wait) {
                vTaskDelay(pdMS_TO_TICKS(20));
            }
        }
        if (network_mqtt_bits_load() & AGENT_ADVERTISE_BIT) result |= 16U;
        if (network_mqtt_bits_load() & AGENT_DISCOVER_BIT) result |= 32U;
        if (network_mqtt_bits_load() & AGENT_RESOLVE_BIT) {
            result |= 64U;
            vTaskDelay(pdMS_TO_TICKS(500));
            topic_length = 0; payload_length = 0;
            if (axoloty_static_agent_prepare(
                    1, 4, agent_output_topic, sizeof(agent_output_topic),
                    agent_output_payload, sizeof(agent_output_payload),
                    &topic_length, &payload_length) && topic_length < (int32_t)sizeof(agent_output_topic)) {
                agent_output_topic[topic_length] = 0;
                if (esp_mqtt_client_publish(
                        mqtt_client, (const char *)agent_output_topic,
                        (const char *)agent_output_payload, payload_length, 0, 0) >= 0) {
                    network_mqtt_bits_set(AGENT_DEADVERTISE_BIT);
                    result |= 128U;
                    vTaskDelay(pdMS_TO_TICKS(500));
                }
            }
        }
    } else {
        while (network_deadline(overall_start, overall_deadline_ms) &&
               !(network_mqtt_bits_load() & AGENT_DEADVERTISE_BIT)) {
            axoloty_static_agent_expire(2);
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        if (network_mqtt_bits_load() & AGENT_ADVERTISE_BIT) result |= 16U;
        if (network_mqtt_bits_load() & AGENT_DISCOVER_BIT) result |= 32U;
        if (network_mqtt_bits_load() & AGENT_RESOLVE_BIT) result |= 64U;
        if (network_mqtt_bits_load() & AGENT_DEADVERTISE_BIT) result |= 128U;
    }

agent_done:
    esp_err_t mqtt_stop_result = !mqtt_started || esp_mqtt_client_stop(mqtt_client) == ESP_OK ? ESP_OK : ESP_FAIL;
    esp_err_t mqtt_destroy_result = !mqtt_client || esp_mqtt_client_destroy(mqtt_client) == ESP_OK ? ESP_OK : ESP_FAIL;
    mqtt_client = NULL;
    network_agent_role = 0;
    network_agent_scenario = 0;
    axoloty_atomic_int_store(&network_flags.forced_wifi_disconnect, 0);
    axoloty_atomic_uint_store(&network_flags.agent_connect_count, 0);
    esp_err_t wifi_disconnect_result = !wifi_started || esp_wifi_disconnect() == ESP_OK ? ESP_OK : ESP_FAIL;
    esp_err_t wifi_stop_result = !wifi_started || esp_wifi_stop() == ESP_OK ? ESP_OK : ESP_FAIL;
    if (wifi_handler_registered) esp_event_handler_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event);
    if (ip_handler_registered) esp_event_handler_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event);
    esp_err_t wifi_deinit_result = !wifi_initialized || esp_wifi_deinit() == ESP_OK ? ESP_OK : ESP_FAIL;
    if (netif) esp_netif_destroy_default_wifi(netif);
    if (event_loop_ready) esp_event_loop_delete_default();
    if (network_events) vEventGroupDelete(network_events);
    network_events = NULL;
    if (mqtt_stop_result == ESP_OK && mqtt_destroy_result == ESP_OK &&
        wifi_disconnect_result == ESP_OK && wifi_stop_result == ESP_OK &&
        wifi_deinit_result == ESP_OK) result |= 256U;
    return result;
#endif
}
