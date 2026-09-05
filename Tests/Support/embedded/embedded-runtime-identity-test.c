// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "runtime_identity.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t mac[6];
    int succeeds;
} MacFixture;

static int read_mac(uint8_t mac[6], void *context) {
    MacFixture *fixture = context;
    if (!fixture->succeeds) return 0;
    memcpy(mac, fixture->mac, 6);
    return 1;
}

int main(void) {
    char first[64];
    char second[64];
    MacFixture fixture = { .mac = { 0x00, 0x11, 0x22, 0xaa, 0xbb, 0xcc }, .succeeds = 1 };

    assert(axoloty_runtime_identity_prepare("", read_mac, &fixture, first, sizeof(first)));
    assert(strcmp(first, "axoloty-001122aabbcc") == 0);
    assert(axoloty_runtime_identity_prepare("", read_mac, &fixture, second, sizeof(second)));
    assert(strcmp(first, second) == 0);

    fixture.mac[5] = 0xcd;
    assert(axoloty_runtime_identity_prepare("", read_mac, &fixture, second, sizeof(second)));
    assert(strcmp(first, second) != 0);
    assert(strcmp(second, "axoloty-001122aabbcd") == 0);

    assert(axoloty_runtime_identity_prepare(
        "site-a-device-01", read_mac, &fixture, second, sizeof(second)));
    assert(strcmp(second, "site-a-device-01") == 0);

    assert(!axoloty_runtime_identity_prepare(
        "bad/name", read_mac, &fixture, second, sizeof(second)));
    assert(!axoloty_runtime_identity_prepare(
        "ümlaut", read_mac, &fixture, second, sizeof(second)));
    assert(!axoloty_runtime_identity_prepare(
        "1234567890123456789012345678901234567890123456789012345678901234",
        read_mac, &fixture, second, sizeof(second)));

    fixture.succeeds = 0;
    assert(axoloty_runtime_identity_prepare(
        "site-a-device-01", read_mac, &fixture, second, sizeof(second)));
    assert(strcmp(second, "site-a-device-01") == 0);
    assert(!axoloty_runtime_identity_prepare("", read_mac, &fixture, second, sizeof(second)));
    return 0;
}
