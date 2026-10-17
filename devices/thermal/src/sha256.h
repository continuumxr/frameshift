// SPDX-License-Identifier: Apache-2.0
#ifndef FS_SHA256_H
#define FS_SHA256_H
#include <stddef.h>
#include <stdint.h>

struct sha256 {
    uint32_t h[8];
    uint64_t len;
    uint8_t buf[64];
    size_t fill;
};

void sha256_init(struct sha256 *c);
void sha256_update(struct sha256 *c, const void *data, size_t n);
void sha256_final(struct sha256 *c, uint8_t out[32]);
void sha256(const void *data, size_t n, uint8_t out[32]);
void sha256_hex(const uint8_t d[32], char out[65]);

#endif
