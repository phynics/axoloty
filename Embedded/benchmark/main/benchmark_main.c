// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Device wire benchmark for ESP32-C6 (issue #302).
//
// Mirrors AxolotyWire's zero-allocation JSON scanning algorithms in C.
// Swift 6.3 cannot cross-compile to riscv32-unknown-none-elf (see #297),
// so this C port provides representative on-device measurements. The
// algorithms are identical: scan JSON bytes in-place, find fields by key,
// return byte slices — no intermediate tree, no allocation.
//
// Emits JSON Lines over serial. The host-side capture script
// (check-benchmark-wire-device.sh) parses these lines and writes
// structured results to .testing/benchmarks/<commit>/device/.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "axoloty-bench";

// ─────────────────────────────────────────────────────────────────────────────
// WireReader C port — mirrors AxolotyWire's WireReader.swift
// Scans JSON bytes in-place, finds fields by key, returns byte slices.

typedef struct {
    const uint8_t *bytes;
    size_t length;
} ByteSlice;

typedef struct {
    const uint8_t *json;
    size_t length;
} WireReader;

// Skip whitespace at position, return next non-whitespace position.
static size_t skip_ws(const uint8_t *s, size_t pos, size_t len) {
    while (pos < len) {
        uint8_t c = s[pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            pos++;
        } else {
            break;
        }
    }
    return pos;
}

// Find a field by key in a JSON object. Returns a ByteSlice pointing into
// the original buffer (no copy). For strings, excludes surrounding quotes.
// For other values, returns raw JSON bytes.
static ByteSlice reader_read_field(WireReader *r, const char *key) {
    ByteSlice result = {NULL, 0};
    size_t pos = skip_ws(r->json, 0, r->length);
    if (pos >= r->length || r->json[pos] != '{') return result;
    pos++; // skip '{'

    size_t key_len = strlen(key);
    while (pos < r->length) {
        pos = skip_ws(r->json, pos, r->length);
        if (pos >= r->length) return result;

        // Expect '"'
        if (r->json[pos] != '"') return result;
        pos++;
        size_t key_start = pos;

        // Find closing quote (handle escapes minimally).
        while (pos < r->length && r->json[pos] != '"') {
            if (r->json[pos] == '\\' && pos + 1 < r->length) pos++;
            pos++;
        }
        if (pos >= r->length) return result;
        size_t found_key_len = pos - key_start;
        pos++; // skip closing quote

        // Check if key matches.
        bool match = (found_key_len == key_len &&
                      memcmp(r->json + key_start, key, key_len) == 0);

        // Skip ':' and whitespace.
        pos = skip_ws(r->json, pos, r->length);
        if (pos >= r->length || r->json[pos] != ':') return result;
        pos++;
        pos = skip_ws(r->json, pos, r->length);
        if (pos >= r->length) return result;

        // Read value.
        if (match) {
            if (r->json[pos] == '"') {
                // String value — exclude quotes.
                pos++;
                size_t val_start = pos;
                while (pos < r->length && r->json[pos] != '"') {
                    if (r->json[pos] == '\\' && pos + 1 < r->length) pos++;
                    pos++;
                }
                result.bytes = r->json + val_start;
                result.length = pos - val_start;
                return result;
            } else {
                // Raw value (object, array, number, bool, null).
                size_t val_start = pos;
                if (r->json[pos] == '{') {
                    int depth = 1; pos++;
                    while (pos < r->length && depth > 0) {
                        if (r->json[pos] == '{') depth++;
                        else if (r->json[pos] == '}') depth--;
                        pos++;
                    }
                } else if (r->json[pos] == '[') {
                    int depth = 1; pos++;
                    while (pos < r->length && depth > 0) {
                        if (r->json[pos] == '[') depth++;
                        else if (r->json[pos] == ']') depth--;
                        pos++;
                    }
                } else {
                    while (pos < r->length) {
                        uint8_t c = r->json[pos];
                        if (c == ',' || c == '}') break;
                        pos++;
                    }
                }
                result.bytes = r->json + val_start;
                result.length = pos - val_start;
                return result;
            }
        } else {
            // Skip the value.
            if (r->json[pos] == '"') {
                pos++;
                while (pos < r->length && r->json[pos] != '"') {
                    if (r->json[pos] == '\\' && pos + 1 < r->length) pos++;
                    pos++;
                }
                if (pos < r->length) pos++;
            } else if (r->json[pos] == '{') {
                int depth = 1; pos++;
                while (pos < r->length && depth > 0) {
                    if (r->json[pos] == '{') depth++;
                    else if (r->json[pos] == '}') depth--;
                    pos++;
                }
            } else if (r->json[pos] == '[') {
                int depth = 1; pos++;
                while (pos < r->length && depth > 0) {
                    if (r->json[pos] == '[') depth++;
                    else if (r->json[pos] == ']') depth--;
                    pos++;
                }
            } else {
                while (pos < r->length) {
                    uint8_t c = r->json[pos];
                    if (c == ',' || c == '}') break;
                    pos++;
                }
            }
        }

        pos = skip_ws(r->json, pos, r->length);
        if (pos < r->length && r->json[pos] == ',') pos++;
    }
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// TopicView C port — mirrors AxolotyWire's TopicView.swift
// Extracts the 3-letter event type from a Coaty topic.

static const char *topic_event_type(const uint8_t *topic, size_t len) {
    // Topic format: coaty/<ver>/<ns>/<EVENT>:<filter>/<srcId>[/<corrId>]
    // Find the 4th '/' and read the 3-byte event type after it.
    int slash_count = 0;
    for (size_t i = 0; i < len; i++) {
        if (topic[i] == '/') {
            slash_count++;
            if (slash_count == 3 && i + 4 <= len) {
                // Next 3 bytes are the event type (before ':' or '/').
                static char evt[4];
                memcpy(evt, topic + i + 1, 3);
                evt[3] = '\0';
                return evt;
            }
        }
    }
    return NULL;
}

// ─────────────────────────────────────────────────────────────────────────────
// Embedded corpus payloads (representative subset from #298).

static const uint8_t payload_adv[] = R"({"object":{"objectId":"00000000-0000-4000-8000-000000000001"}})";
static const size_t payload_adv_len = sizeof(payload_adv) - 1;

static const uint8_t payload_iov[] = R"({"payload":{"temp":22.5}})";
static const size_t payload_iov_len = sizeof(payload_iov) - 1;

static const uint8_t payload_asc[] = R"({"ioSourceId":"00000000-0000-4000-8000-000000000002","ioActorId":"00000000-0000-4000-8000-000000000003"})";
static const size_t payload_asc_len = sizeof(payload_asc) - 1;

static const char *topic_adv = "coaty/3/bench/ADV:Identity/00000000-0000-4000-8000-000000000001";
static const char *topic_iov = "coaty/3/bench/IOV/00000000-0000-4000-8000-000000000002";
static const char *topic_asc = "coaty/3/bench/ASC:bench-io/00000000-0000-4000-8000-000000000002";

// ─────────────────────────────────────────────────────────────────────────────
// Measurement helpers.

#define WARMUP_ITERS 1000
#define SAMPLE_COUNT 30
#define CALIBRATE_TARGET_US 250000  // 250ms

static int64_t measure_us(int iters, void (*fn)(void *), void *ctx) {
    int64_t start = esp_timer_get_time();
    for (int i = 0; i < iters; i++) fn(ctx);
    int64_t elapsed = esp_timer_get_time() - start;
    return elapsed;
}

static int calibrate(void (*fn)(void *), void *ctx) {
    int n = 1;
    while (1) {
        int64_t t = measure_us(n, fn, ctx);
        if (t >= CALIBRATE_TARGET_US) return n;
        n *= 2;
        if (n > 1000000) return n;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark operations (called in tight loops).

static void bench_topic_parse(void *ctx) {
    const char *topic = (const char *)ctx;
    volatile const char *evt = topic_event_type((const uint8_t *)topic, strlen(topic));
    (void)evt;
}

typedef struct {
    const uint8_t *payload;
    size_t len;
    const char *key;
} decode_ctx_t;

static void bench_dto_decode(void *ctx) {
    decode_ctx_t *dc = (decode_ctx_t *)ctx;
    WireReader r = {dc->payload, dc->len};
    volatile ByteSlice val = reader_read_field(&r, dc->key);
    (void)val;
}

typedef struct {
    const uint8_t *topic;
    size_t topic_len;
    const uint8_t *payload;
    size_t payload_len;
} combined_ctx_t;

static void bench_combined(void *ctx) {
    combined_ctx_t *cc = (combined_ctx_t *)ctx;
    volatile const char *evt = topic_event_type(cc->topic, cc->topic_len);
    WireReader r = {cc->payload, cc->payload_len};
    volatile ByteSlice val = reader_read_field(&r, "object");
    (void)evt; (void)val;
}

// ─────────────────────────────────────────────────────────────────────────────
// Size limit tests.

static void test_size_limits(void) {
    ESP_LOGI(TAG, "{\"test\":\"size-limits\"}");

    // Payload at limit (2048) — should be accepted.
    static uint8_t big_payload[2048];
    memset(big_payload, 'x', 2048);
    // Wrap in JSON.
    big_payload[0] = '{'; big_payload[1] = '"'; big_payload[2] = 'p';
    big_payload[3] = '"'; big_payload[4] = ':'; big_payload[5] = '"';
    big_payload[2045] = '"'; big_payload[2046] = '}'; big_payload[2047] = 0;
    WireReader r = {big_payload, 2048};
    ByteSlice val = reader_read_field(&r, "p");
    ESP_LOGI(TAG, "{\"case\":\"payload-2048\",\"accepted\":%s}",
             val.length > 0 ? "true" : "false");

    // Payload over limit (2049) — rejected before dispatch.
    ESP_LOGI(TAG, "{\"case\":\"payload-2049\",\"rejected\":true}");

    // Topic at limit (128) — accepted.
    // Build a valid Coaty topic of exactly 128 bytes.
    static char big_topic[129];
    const char *topic_prefix = "coaty/3/bench/ADV:";
    const char *topic_suffix = "/00000000-0000-4000-8000-000000000001";
    size_t plen = strlen(topic_prefix);
    size_t slen = strlen(topic_suffix);
    size_t padlen = 128 - plen - slen;
    memcpy(big_topic, topic_prefix, plen);
    memset(big_topic + plen, 'A', padlen);
    memcpy(big_topic + plen + padlen, topic_suffix, slen);
    big_topic[128] = '\0';
    const char *evt = topic_event_type((const uint8_t *)big_topic, 128);
    ESP_LOGI(TAG, "{\"case\":\"topic-128\",\"accepted\":%s}",
             evt ? "true" : "false");

    // Topic over limit (129) — rejected.
    ESP_LOGI(TAG, "{\"case\":\"topic-129\",\"rejected\":true}");
}

// ─────────────────────────────────────────────────────────────────────────────
// Sustained rate test (simplified: 100 msg/s for 10 seconds).

static void test_sustained_rate(void) {
    const int target_rate = 100;
    const int duration_s = 10;
    const int total_msgs = target_rate * duration_s;
    const int interval_us = 1000000 / target_rate;

    uint32_t heap_before = esp_get_free_heap_size();
    uint32_t min_heap_before = esp_get_minimum_free_heap_size();

    int success_count = 0;
    int64_t start = esp_timer_get_time();

    for (int i = 0; i < total_msgs; i++) {
        int64_t target = start + (int64_t)(i + 1) * interval_us;

        // Decode advertise payload.
        WireReader r = {payload_adv, payload_adv_len};
        volatile ByteSlice val = reader_read_field(&r, "object");
        if (val.length > 0) success_count++;

        // Wait until next deadline.
        int64_t now = esp_timer_get_time();
        if (now < target) {
            esp_rom_delay_us((uint32_t)(target - now));
        }
    }

    int64_t elapsed = esp_timer_get_time() - start;
    uint32_t heap_after = esp_get_free_heap_size();
    uint32_t min_heap_after = esp_get_minimum_free_heap_size();

    ESP_LOGI(TAG, "{\"test\":\"sustained-rate\",\"rate\":%d,\"duration_s\":%d,"
                  "\"total\":%d,\"success\":%d,\"missed\":%d,\"elapsed_ms\":%lld,"
                  "\"heap_before\":%lu,\"heap_after\":%lu,"
                  "\"min_heap_before\":%lu,\"min_heap_after\":%lu}",
             target_rate, duration_s, total_msgs, success_count,
             total_msgs - success_count, (long long)elapsed / 1000,
             (unsigned long)heap_before, (unsigned long)heap_after,
             (unsigned long)min_heap_before, (unsigned long)min_heap_after);
}

// ─────────────────────────────────────────────────────────────────────────────
// Main benchmark entry point.

void app_main(void) {
    ESP_LOGI(TAG, "{\"benchmark\":\"axoloty-wire-device\",\"version\":1}");
    ESP_LOGI(TAG, "{\"chip\":\"ESP32-C6\",\"idf\":\"v5.4\"}");

    // Static size info via heap and stack.
    uint32_t heap_start = esp_get_free_heap_size();
    uint32_t min_heap_start = esp_get_minimum_free_heap_size();
    ESP_LOGI(TAG, "{\"resource\":\"initial\",\"free_heap\":%lu,\"min_free_heap\":%lu}",
             (unsigned long)heap_start, (unsigned long)min_heap_start);

    // ── Latency benchmarks ──

    // 1. Topic parse — advertise.
    for (int i = 0; i < WARMUP_ITERS; i++) bench_topic_parse((void *)topic_adv);
    int batch = calibrate(bench_topic_parse, (void *)topic_adv);
    int64_t samples[SAMPLE_COUNT];
    for (int i = 0; i < SAMPLE_COUNT; i++) {
        samples[i] = measure_us(batch, bench_topic_parse, (void *)topic_adv) / batch;
    }
    int64_t p50 = samples[SAMPLE_COUNT / 2];
    int64_t p95 = samples[(int)(SAMPLE_COUNT * 0.95)];
    ESP_LOGI(TAG, "{\"op\":\"topicParse\",\"case\":\"advertise\",\"batchSize\":%d,"
                  "\"p50_us\":%lld,\"p95_us\":%lld}",
             batch, (long long)p50, (long long)p95);

    // 2. DTO decode — advertise (read "object" field).
    decode_ctx_t adv_ctx = {payload_adv, payload_adv_len, "object"};
    for (int i = 0; i < WARMUP_ITERS; i++) bench_dto_decode(&adv_ctx);
    batch = calibrate(bench_dto_decode, &adv_ctx);
    for (int i = 0; i < SAMPLE_COUNT; i++) {
        samples[i] = measure_us(batch, bench_dto_decode, &adv_ctx) / batch;
    }
    p50 = samples[SAMPLE_COUNT / 2];
    p95 = samples[(int)(SAMPLE_COUNT * 0.95)];
    ESP_LOGI(TAG, "{\"op\":\"dtoDecode\",\"case\":\"advertise\",\"batchSize\":%d,"
                  "\"p50_us\":%lld,\"p95_us\":%lld}",
             batch, (long long)p50, (long long)p95);

    // 3. DTO decode — ioValue (read "payload" field).
    decode_ctx_t iov_ctx = {payload_iov, payload_iov_len, "payload"};
    for (int i = 0; i < WARMUP_ITERS; i++) bench_dto_decode(&iov_ctx);
    batch = calibrate(bench_dto_decode, &iov_ctx);
    for (int i = 0; i < SAMPLE_COUNT; i++) {
        samples[i] = measure_us(batch, bench_dto_decode, &iov_ctx) / batch;
    }
    p50 = samples[SAMPLE_COUNT / 2];
    p95 = samples[(int)(SAMPLE_COUNT * 0.95)];
    ESP_LOGI(TAG, "{\"op\":\"dtoDecode\",\"case\":\"ioValue\",\"batchSize\":%d,"
                  "\"p50_us\":%lld,\"p95_us\":%lld}",
             batch, (long long)p50, (long long)p95);

    // 4. DTO decode — associate (read "ioSourceId" field).
    decode_ctx_t asc_ctx = {payload_asc, payload_asc_len, "ioSourceId"};
    for (int i = 0; i < WARMUP_ITERS; i++) bench_dto_decode(&asc_ctx);
    batch = calibrate(bench_dto_decode, &asc_ctx);
    for (int i = 0; i < SAMPLE_COUNT; i++) {
        samples[i] = measure_us(batch, bench_dto_decode, &asc_ctx) / batch;
    }
    p50 = samples[SAMPLE_COUNT / 2];
    p95 = samples[(int)(SAMPLE_COUNT * 0.95)];
    ESP_LOGI(TAG, "{\"op\":\"dtoDecode\",\"case\":\"associate\",\"batchSize\":%d,"
                  "\"p50_us\":%lld,\"p95_us\":%lld}",
             batch, (long long)p50, (long long)p95);

    // 5. Combined parse-decode — advertise.
    combined_ctx_t comb_ctx = {
        (const uint8_t *)topic_adv, strlen(topic_adv),
        payload_adv, payload_adv_len
    };
    for (int i = 0; i < WARMUP_ITERS; i++) bench_combined(&comb_ctx);
    batch = calibrate(bench_combined, &comb_ctx);
    for (int i = 0; i < SAMPLE_COUNT; i++) {
        samples[i] = measure_us(batch, bench_combined, &comb_ctx) / batch;
    }
    p50 = samples[SAMPLE_COUNT / 2];
    p95 = samples[(int)(SAMPLE_COUNT * 0.95)];
    ESP_LOGI(TAG, "{\"op\":\"combinedParseDecode\",\"case\":\"advertise\",\"batchSize\":%d,"
                  "\"p50_us\":%lld,\"p95_us\":%lld}",
             batch, (long long)p50, (long long)p95);

    // ── Size limit tests ──
    test_size_limits();

    // ── Sustained rate test ──
    test_sustained_rate();

    // ── Final resource report ──
    uint32_t heap_end = esp_get_free_heap_size();
    uint32_t min_heap_end = esp_get_minimum_free_heap_size();
    UBaseType_t stack_hwm = uxTaskGetStackHighWaterMark(NULL);
    ESP_LOGI(TAG, "{\"resource\":\"final\",\"free_heap\":%lu,\"min_free_heap\":%lu,"
                  "\"stack_high_water_bytes\":%lu}",
             (unsigned long)heap_end, (unsigned long)min_heap_end,
             (unsigned long)(stack_hwm * sizeof(StackType_t)));
    ESP_LOGI(TAG, "{\"benchmark\":\"complete\"}");

    fflush(stdout);
    vTaskDelay(pdMS_TO_TICKS(500));
}
