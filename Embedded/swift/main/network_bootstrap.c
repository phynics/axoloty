// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Deliberately synchronous Wi-Fi/MQTT test façade. ESP-MQTT callbacks only
// inspect or copy bounded data while they execute; no callback pointer escapes.

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "mqtt_client.h"
#include "nvs_flash.h"
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
#endif

#define WIFI_BIT (1U << 0)
#define IP_BIT (1U << 1)
#define WIFI_FAIL_BIT (1U << 2)
#define NETWORK_MAX_TOPIC 129
#define NETWORK_MAX_PAYLOAD 513
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

static EventGroupHandle_t network_events;
static esp_mqtt_client_handle_t mqtt_client;
static volatile unsigned network_mqtt_bits;
static char network_topic[NETWORK_MAX_TOPIC];
static char network_payload[NETWORK_MAX_PAYLOAD];
static size_t network_payload_length;
static unsigned int network_agent_role;
static uint8_t agent_output_topic[NETWORK_MAX_TOPIC];
static uint8_t agent_output_payload[NETWORK_MAX_PAYLOAD];
static uint8_t agent_will_topic[NETWORK_MAX_TOPIC];
static uint8_t agent_will_payload[NETWORK_MAX_PAYLOAD];

static void network_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == IP_EVENT_STA_GOT_IP) xEventGroupSetBits(network_events, IP_BIT);
}

static void network_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg; (void)base; (void)data;
    if (id == WIFI_EVENT_STA_START) esp_wifi_connect();
    else if (id == WIFI_EVENT_STA_DISCONNECTED) xEventGroupSetBits(network_events, WIFI_FAIL_BIT);
}

static void network_mqtt_event(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    (void)handler_args; (void)base;
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;
    if (event_id == MQTT_EVENT_CONNECTED) network_mqtt_bits |= network_agent_role ? AGENT_CONNECTED_BIT : 4U;
    else if (event_id == MQTT_EVENT_SUBSCRIBED) network_mqtt_bits |= network_agent_role ? AGENT_SUBSCRIBED_BIT : 8U;
    else if (event_id == MQTT_EVENT_PUBLISHED) network_mqtt_bits |= 16U;
    else if (event_id == MQTT_EVENT_DATA && network_agent_role && event && event->topic && event->data &&
             event->current_data_offset == 0 && event->data_len == event->total_data_len) {
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
            if (network_agent_role == 1U) network_mqtt_bits |= AGENT_DISCOVER_BIT;
            else network_mqtt_bits |= AGENT_ADVERTISE_BIT;
            if (output_topic_length > 0 && output_topic_length < (int32_t)sizeof(agent_output_topic)) {
                agent_output_topic[output_topic_length] = 0;
            }
            if (output_topic_length > 0 && output_topic_length < (int32_t)sizeof(agent_output_topic) &&
                esp_mqtt_client_publish(
                    mqtt_client, (const char *)agent_output_topic,
                    (const char *)agent_output_payload, output_payload_length, 0, 0) >= 0) {
                if (network_agent_role == 1U) network_mqtt_bits |= AGENT_RESOLVE_BIT;
                else network_mqtt_bits |= AGENT_DISCOVER_BIT;
            }
        } else if (action == 2 && network_agent_role == 2U) {
            network_mqtt_bits |= AGENT_RESOLVE_BIT;
        } else if (action == 3 && network_agent_role == 2U) {
            network_mqtt_bits |= AGENT_DEADVERTISE_BIT;
        }
    } else if (event_id == MQTT_EVENT_DATA && event && event->topic && event->data &&
             event->topic_len == (int)strlen(network_topic) &&
             event->data_len == (int)network_payload_length &&
             memcmp(event->topic, network_topic, event->topic_len) == 0 &&
             memcmp(event->data, network_payload, event->data_len) == 0) {
        network_mqtt_bits |= 32U;
    }
}

static int network_deadline(uint32_t start, uint32_t timeout) {
    return (uint32_t)(esp_timer_get_time() / 1000ULL) - start < timeout;
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

unsigned int axoloty_network_test(unsigned int overall_deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)overall_deadline_ms;
    return 0;
#else
    const uint32_t overall_start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    unsigned result = 0;
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        if (nvs_flash_erase() != ESP_OK) return 0;
        err = nvs_flash_init();
    }
    if (err != ESP_OK) return 0;
    if (esp_netif_init() != ESP_OK || esp_event_loop_create_default() != ESP_OK) return 0;
    network_events = xEventGroupCreate();
    if (!network_events) return 0;
    esp_netif_t *netif = esp_netif_create_default_wifi_sta();
    if (!netif) return 0;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (esp_wifi_init(&init) != ESP_OK) return 0;
    if (esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event, NULL) != ESP_OK ||
        esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event, NULL) != ESP_OK) return 0;
    wifi_config_t wifi = { 0 };
    memcpy(wifi.sta.ssid, axoloty_wifi_ssid, axoloty_wifi_ssid_length);
    memcpy(wifi.sta.password, axoloty_wifi_password, axoloty_wifi_password_length);
    wifi.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK || esp_wifi_set_config(WIFI_IF_STA, &wifi) != ESP_OK ||
        esp_wifi_start() != ESP_OK) return 0;
    EventBits_t bits = xEventGroupWaitBits(network_events, WIFI_FAIL_BIT | IP_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(30000));
    if ((bits & IP_BIT) == 0 || !network_deadline(overall_start, overall_deadline_ms)) return 0;
    result |= 1U | 2U;

    uint32_t stamp = (uint32_t)(esp_timer_get_time() / 1000ULL);
    int topic_length = snprintf(network_topic, sizeof(network_topic), "axoloty/network/%u", (unsigned)stamp);
    int payload_length = snprintf(network_payload, sizeof(network_payload), "axoloty-network-%u", (unsigned)stamp);
    if (topic_length <= 0 || payload_length <= 0 || topic_length >= (int)sizeof(network_topic) || payload_length >= (int)sizeof(network_payload)) return result;
    network_payload_length = (size_t)payload_length;
    char uri[128];
    int uri_length = snprintf(uri, sizeof(uri), "mqtt://%s:%u", axoloty_mqtt_host, (unsigned)axoloty_mqtt_port);
    if (uri_length <= 0 || uri_length >= (int)sizeof(uri)) return result;
    esp_mqtt_client_config_t config = { .broker.address.uri = uri };
    network_mqtt_bits = 0;
    mqtt_client = esp_mqtt_client_init(&config);
    if (!mqtt_client || esp_mqtt_client_register_event(mqtt_client, ESP_EVENT_ANY_ID, network_mqtt_event, NULL) != ESP_OK ||
        esp_mqtt_client_start(mqtt_client) != ESP_OK) return result;
    uint32_t mqtt_start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(overall_start, overall_deadline_ms) && network_deadline(mqtt_start, 15000) && !(network_mqtt_bits & 4U)) vTaskDelay(pdMS_TO_TICKS(20));
    if (network_mqtt_bits & 4U) result |= 4U; else goto done;
    if (esp_mqtt_client_subscribe(mqtt_client, network_topic, 0) < 0) goto done;
    mqtt_start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(overall_start, overall_deadline_ms) && network_deadline(mqtt_start, 10000) && !(network_mqtt_bits & 8U)) vTaskDelay(pdMS_TO_TICKS(20));
    if (network_mqtt_bits & 8U) result |= 8U; else goto done;
    if (esp_mqtt_client_publish(mqtt_client, network_topic, network_payload, (int)network_payload_length, 0, 0) < 0) goto done;
    result |= 16U;
    mqtt_start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    while (network_deadline(overall_start, overall_deadline_ms) && network_deadline(mqtt_start, 10000) && !(network_mqtt_bits & 32U)) vTaskDelay(pdMS_TO_TICKS(20));
    if (network_mqtt_bits & 32U) result |= 32U;
done:
    esp_err_t mqtt_stop_result = ESP_OK;
    esp_err_t mqtt_destroy_result = ESP_OK;
    if (mqtt_client) {
        mqtt_stop_result = esp_mqtt_client_stop(mqtt_client);
        mqtt_destroy_result = esp_mqtt_client_destroy(mqtt_client);
        mqtt_client = NULL;
    }
    esp_event_handler_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event);
    esp_event_handler_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event);
    esp_err_t wifi_disconnect_result = esp_wifi_disconnect();
    esp_err_t wifi_stop_result = esp_wifi_stop();
    esp_err_t wifi_deinit_result = esp_wifi_deinit();
    esp_netif_destroy_default_wifi(netif);
    esp_event_loop_delete_default();
    vEventGroupDelete(network_events);
    network_events = NULL;
    if (mqtt_stop_result == ESP_OK && mqtt_destroy_result == ESP_OK &&
        wifi_disconnect_result == ESP_OK && wifi_stop_result == ESP_OK &&
        wifi_deinit_result == ESP_OK) result |= 64U;
    return result;
#endif
}

unsigned int axoloty_agent_test(unsigned int overall_deadline_ms) {
#if !AXOLOTY_NETWORK_CONFIGURED
    (void)overall_deadline_ms;
    return 0;
#else
    if (axoloty_device_role != 1U && axoloty_device_role != 2U) return 0;
    const uint32_t overall_start = (uint32_t)(esp_timer_get_time() / 1000ULL);
    unsigned int result = 0;
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        if (nvs_flash_erase() != ESP_OK) return 0;
        err = nvs_flash_init();
    }
    if (err != ESP_OK) return 0;
    if (esp_netif_init() != ESP_OK || esp_event_loop_create_default() != ESP_OK) return 0;
    network_events = xEventGroupCreate();
    if (!network_events) return 0;
    esp_netif_t *netif = esp_netif_create_default_wifi_sta();
    if (!netif) return 0;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (esp_wifi_init(&init) != ESP_OK) return 0;
    if (esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event, NULL) != ESP_OK ||
        esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event, NULL) != ESP_OK) return 0;
    wifi_config_t wifi = { 0 };
    memcpy(wifi.sta.ssid, axoloty_wifi_ssid, axoloty_wifi_ssid_length);
    memcpy(wifi.sta.password, axoloty_wifi_password, axoloty_wifi_password_length);
    wifi.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK || esp_wifi_set_config(WIFI_IF_STA, &wifi) != ESP_OK ||
        esp_wifi_start() != ESP_OK) return 0;
    EventBits_t wifi_bits = xEventGroupWaitBits(
        network_events, WIFI_FAIL_BIT | IP_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(30000));
    if ((wifi_bits & IP_BIT) == 0 || !network_deadline(overall_start, overall_deadline_ms)) return 0;
    result |= 1U | 2U;

    char uri[128];
    int uri_length = snprintf(uri, sizeof(uri), "mqtt://%s:%u", axoloty_mqtt_host, (unsigned)axoloty_mqtt_port);
    if (uri_length <= 0 || uri_length >= (int)sizeof(uri)) return result;
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

    esp_mqtt_client_config_t config = { 0 };
    config.broker.address.uri = uri;
    config.credentials.client_id = axoloty_device_role == 1U ? "axoloty-esp32-a" : "axoloty-esp32-b";
    if (has_will) {
        config.session.last_will.topic = (const char *)agent_will_topic;
        config.session.last_will.msg = (const char *)agent_will_payload;
        config.session.last_will.msg_len = will_payload_length;
        config.session.last_will.qos = 0;
        config.session.last_will.retain = 0;
    }
    network_agent_role = axoloty_device_role;
    network_mqtt_bits = 0;
    mqtt_client = esp_mqtt_client_init(&config);
    if (!mqtt_client || esp_mqtt_client_register_event(mqtt_client, ESP_EVENT_ANY_ID, network_mqtt_event, NULL) != ESP_OK ||
        esp_mqtt_client_start(mqtt_client) != ESP_OK) return result;
    while (network_deadline(overall_start, overall_deadline_ms) && !(network_mqtt_bits & AGENT_CONNECTED_BIT)) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!(network_mqtt_bits & AGENT_CONNECTED_BIT)) goto agent_done;
    result |= 4U;
    if (esp_mqtt_client_subscribe(mqtt_client, "coaty/3/axoloty-embedded/#", 0) < 0) goto agent_done;
    while (network_deadline(overall_start, overall_deadline_ms) && !(network_mqtt_bits & AGENT_SUBSCRIBED_BIT)) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!(network_mqtt_bits & AGENT_SUBSCRIBED_BIT)) goto agent_done;
    result |= 8U;

    if (axoloty_device_role == 1U) {
        int32_t topic_length = 0;
        int32_t payload_length = 0;
        if (!axoloty_static_agent_prepare(
                1, 1, agent_output_topic, sizeof(agent_output_topic),
                agent_output_payload, sizeof(agent_output_payload),
                &topic_length, &payload_length) || topic_length >= (int32_t)sizeof(agent_output_topic)) goto agent_done;
        agent_output_topic[topic_length] = 0;
        while (network_deadline(overall_start, overall_deadline_ms) &&
               !(network_mqtt_bits & AGENT_DISCOVER_BIT)) {
            if (esp_mqtt_client_publish(
                    mqtt_client, (const char *)agent_output_topic,
                    (const char *)agent_output_payload, payload_length, 0, 0) >= 0) {
                network_mqtt_bits |= AGENT_ADVERTISE_BIT;
            }
            for (int wait = 0; wait < 100 && !(network_mqtt_bits & AGENT_DISCOVER_BIT); ++wait) {
                vTaskDelay(pdMS_TO_TICKS(20));
            }
        }
        if (network_mqtt_bits & AGENT_ADVERTISE_BIT) result |= 16U;
        if (network_mqtt_bits & AGENT_DISCOVER_BIT) result |= 32U;
        if (network_mqtt_bits & AGENT_RESOLVE_BIT) {
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
                    network_mqtt_bits |= AGENT_DEADVERTISE_BIT;
                    result |= 128U;
                    vTaskDelay(pdMS_TO_TICKS(500));
                }
            }
        }
    } else {
        while (network_deadline(overall_start, overall_deadline_ms) &&
               !(network_mqtt_bits & AGENT_DEADVERTISE_BIT)) {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        if (network_mqtt_bits & AGENT_ADVERTISE_BIT) result |= 16U;
        if (network_mqtt_bits & AGENT_DISCOVER_BIT) result |= 32U;
        if (network_mqtt_bits & AGENT_RESOLVE_BIT) result |= 64U;
        if (network_mqtt_bits & AGENT_DEADVERTISE_BIT) result |= 128U;
    }

agent_done:
    esp_err_t mqtt_stop_result = mqtt_client ? esp_mqtt_client_stop(mqtt_client) : ESP_FAIL;
    esp_err_t mqtt_destroy_result = mqtt_client ? esp_mqtt_client_destroy(mqtt_client) : ESP_FAIL;
    mqtt_client = NULL;
    network_agent_role = 0;
    esp_event_handler_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, network_wifi_event);
    esp_event_handler_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, network_ip_event);
    esp_err_t wifi_disconnect_result = esp_wifi_disconnect();
    esp_err_t wifi_stop_result = esp_wifi_stop();
    esp_err_t wifi_deinit_result = esp_wifi_deinit();
    esp_netif_destroy_default_wifi(netif);
    esp_event_loop_delete_default();
    vEventGroupDelete(network_events);
    network_events = NULL;
    if (mqtt_stop_result == ESP_OK && mqtt_destroy_result == ESP_OK &&
        wifi_disconnect_result == ESP_OK && wifi_stop_result == ESP_OK &&
        wifi_deinit_result == ESP_OK) result |= 256U;
    return result;
#endif
}
