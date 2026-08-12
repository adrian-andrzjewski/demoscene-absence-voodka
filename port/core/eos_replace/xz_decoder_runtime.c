/* xz_decoder_runtime.c - fixed workspace and byte primitives for VOODKA. */

#include <stddef.h>

#define VOODKA_XZ_WORKSPACE_BYTES (128u * 1024u)

static unsigned char g_voodka_xz_workspace[VOODKA_XZ_WORKSPACE_BYTES];
static size_t g_voodka_xz_cursor;

void voodka_xz_workspace_reset(void) {
    g_voodka_xz_cursor = 0;
}

void *voodka_xz_alloc(size_t size) {
    const size_t aligned = (size + 15u) & ~(size_t)15u;
    if (aligned > VOODKA_XZ_WORKSPACE_BYTES - g_voodka_xz_cursor)
        return (void *)0;
    void *result = g_voodka_xz_workspace + g_voodka_xz_cursor;
    g_voodka_xz_cursor += aligned;
    return result;
}

void voodka_xz_free(void *ptr) {
    (void)ptr;
}

void *voodka_xz_memcpy(void *dst, const void *src, size_t size) {
    volatile unsigned char *d = (volatile unsigned char *)dst;
    const volatile unsigned char *s = (const volatile unsigned char *)src;
    for (size_t i = 0; i < size; ++i) d[i] = s[i];
    return dst;
}

void *voodka_xz_memmove(void *dst, const void *src, size_t size) {
    volatile unsigned char *d = (volatile unsigned char *)dst;
    const volatile unsigned char *s = (const volatile unsigned char *)src;
    if (d < s) {
        for (size_t i = 0; i < size; ++i) d[i] = s[i];
    } else if (d > s) {
        for (size_t i = size; i != 0; --i) d[i - 1] = s[i - 1];
    }
    return dst;
}

void *voodka_xz_memset(void *dst, int value, size_t size) {
    volatile unsigned char *d = (volatile unsigned char *)dst;
    for (size_t i = 0; i < size; ++i) d[i] = (unsigned char)value;
    return dst;
}

int voodka_xz_memcmp(const void *left, const void *right, size_t size) {
    const unsigned char *a = (const unsigned char *)left;
    const unsigned char *b = (const unsigned char *)right;
    for (size_t i = 0; i < size; ++i) {
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}
