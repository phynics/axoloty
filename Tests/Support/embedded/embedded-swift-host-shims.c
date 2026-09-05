// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <stddef.h>
#include <string.h>

// Ubuntu 22.04's glibc predates arc4random_buf. Embedded Swift uses it only
// to seed hash tables in this short-lived deterministic test executable.
void arc4random_buf(void *buffer, size_t count) {
    memset(buffer, 0, count);
}
