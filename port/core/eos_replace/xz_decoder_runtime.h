/* xz_decoder_runtime.h - no-CRT configuration for XZ Embedded. */

#ifndef VOODKA_XZ_DECODER_RUNTIME_H
#define VOODKA_XZ_DECODER_RUNTIME_H

#include "../../../modules/libxmp/src/depackers/xz.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *voodka_xz_alloc(size_t size);
void voodka_xz_free(void *ptr);
void *voodka_xz_memcpy(void *dst, const void *src, size_t size);
void *voodka_xz_memmove(void *dst, const void *src, size_t size);
void *voodka_xz_memset(void *dst, int value, size_t size);
int voodka_xz_memcmp(const void *left, const void *right, size_t size);
void voodka_xz_workspace_reset(void);

#ifdef __cplusplus
}
#endif

#define XZ_DEC_SINGLE 1

#define kmalloc(size, flags) voodka_xz_alloc((size))
#define kfree(ptr) voodka_xz_free((ptr))
#define vmalloc(size) voodka_xz_alloc((size))
#define vfree(ptr) voodka_xz_free((ptr))

#define memcpy voodka_xz_memcpy
#define memmove voodka_xz_memmove
#define memset voodka_xz_memset
#define memeq(a, b, size) (voodka_xz_memcmp((a), (b), (size)) == 0)
#define memzero(buf, size) voodka_xz_memset((buf), 0, (size))

static inline uint32 voodka_xz_get_le32(const uint8 *buf) {
    return (uint32)buf[0] |
           ((uint32)buf[1] << 8) |
           ((uint32)buf[2] << 16) |
           ((uint32)buf[3] << 24);
}
#define get_le32 voodka_xz_get_le32

#ifndef min
#define min(x, y) ((x) < (y) ? (x) : (y))
#endif
#define min_t(type, x, y) min((x), (y))

#endif
