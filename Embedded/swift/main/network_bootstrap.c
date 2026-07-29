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
#define NETWORK_MAX_TOPIC 96
#define NETWORK_MAX_PAYLOAD 96

static EventGroupHandle_t network_events;
static esp_mqtt_client_handle_t mqtt_client;
static volatile unsigned network_mqtt_bits;
static char network_topic[NETWORK_MAX_TOPIC];
static char network_payload[NETWORK_MAX_PAYLOAD];
static size_t network_payload_length;

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
    if (event_id == MQTT_EVENT_CONNECTED) network_mqtt_bits |= 4U;
    else if (event_id == MQTT_EVENT_SUBSCRIBED) network_mqtt_bits |= 8U;
    else if (event_id == MQTT_EVENT_PUBLISHED) network_mqtt_bits |= 16U;
    else if (event_id == MQTT_EVENT_DATA && event && event->topic && event->data &&
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
