// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_EMBEDDED_SHARED_FLAGS_H
#define AXOLOTY_EMBEDDED_SHARED_FLAGS_H

typedef unsigned AxolotyAtomicUInt;
typedef int AxolotyAtomicInt;

// State exchanged between ESP event callbacks and the main execution task.
// The acquire/release operations make callback-produced state visible to the
// polling task, while acq_rel read-modify-write operations preserve updates
// when both contexts set or clear bits concurrently.
typedef struct {
    AxolotyAtomicUInt mqtt_bits;
    AxolotyAtomicUInt agent_connect_count;
    AxolotyAtomicUInt network_connect_count;
    AxolotyAtomicUInt wifi_retry_count;
    AxolotyAtomicInt forced_wifi_disconnect;
} AxolotyEmbeddedSharedFlags;

static inline unsigned axoloty_atomic_uint_load(const AxolotyAtomicUInt *value) {
    return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

static inline void axoloty_atomic_uint_store(AxolotyAtomicUInt *value, unsigned value_to_store) {
    __atomic_store_n(value, value_to_store, __ATOMIC_RELEASE);
}

static inline unsigned axoloty_atomic_uint_fetch_add(AxolotyAtomicUInt *value, unsigned amount) {
    return __atomic_fetch_add(value, amount, __ATOMIC_ACQ_REL);
}

static inline unsigned axoloty_atomic_uint_fetch_or(AxolotyAtomicUInt *value, unsigned bits) {
    return __atomic_fetch_or(value, bits, __ATOMIC_ACQ_REL);
}

static inline unsigned axoloty_atomic_uint_fetch_and(AxolotyAtomicUInt *value, unsigned bits) {
    return __atomic_fetch_and(value, bits, __ATOMIC_ACQ_REL);
}

static inline int axoloty_atomic_int_load(const AxolotyAtomicInt *value) {
    return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

static inline void axoloty_atomic_int_store(AxolotyAtomicInt *value, int value_to_store) {
    __atomic_store_n(value, value_to_store, __ATOMIC_RELEASE);
}

#endif
