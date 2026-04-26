/**
 * @file n00b_shim.c
 * @brief Plain-C implementation of the n00b shim used by the carved
 *        Mach-O parser/builder.  Single-threaded; no locks.
 */

#include "n00b_shim.h"

// ============================================================================
// Buffer
// ============================================================================

n00b_buffer_t *
n00b_buffer_new(int64_t capacity)
{
    if (capacity < 0) {
        capacity = 0;
    }

    n00b_buffer_t *buf = (n00b_buffer_t *)calloc(1, sizeof(*buf));

    size_t alloc = capacity > 0 ? (size_t)capacity : 16;
    buf->data      = (char *)calloc(1, alloc);
    buf->byte_len  = 0;
    buf->alloc_len = alloc;
    return buf;
}

n00b_buffer_t *
n00b_buffer_from_bytes(char *bytes, int64_t len)
{
    if (len < 0) {
        len = 0;
    }

    n00b_buffer_t *buf = (n00b_buffer_t *)calloc(1, sizeof(*buf));

    size_t alloc = len > 0 ? (size_t)len : 16;
    buf->data      = (char *)calloc(1, alloc);
    buf->byte_len  = (size_t)len;
    buf->alloc_len = alloc;

    if (len > 0 && bytes) {
        memcpy(buf->data, bytes, (size_t)len);
    }

    return buf;
}

void
n00b_buffer_resize(n00b_buffer_t *buf, uint64_t new_sz)
{
    if (!buf) {
        return;
    }

    if (new_sz > buf->alloc_len) {
        size_t new_cap = buf->alloc_len ? buf->alloc_len : 16;

        while (new_cap < new_sz) {
            new_cap *= 2;
        }

        char *new_data = (char *)realloc(buf->data, new_cap);

        if (!new_data) {
            // Allocation failure — leave buf untouched and let caller
            // observe via byte_len < required.
            return;
        }

        // Zero the newly grown portion to match n00b semantics.
        memset(new_data + buf->alloc_len, 0, new_cap - buf->alloc_len);

        buf->data      = new_data;
        buf->alloc_len = new_cap;
    }

    buf->byte_len = (size_t)new_sz;
}

int64_t
n00b_buffer_len(n00b_buffer_t *buf)
{
    return buf ? (int64_t)buf->byte_len : 0;
}

void
n00b_buffer_free(n00b_buffer_t *buf)
{
    if (!buf) {
        return;
    }

    free(buf->data);
    buf->data      = NULL;
    buf->byte_len  = 0;
    buf->alloc_len = 0;
}

void
n00b_buffer_destroy(n00b_buffer_t *buf)
{
    if (!buf) {
        return;
    }

    free(buf->data);
    free(buf);
}

// ============================================================================
// String
//
// n00b strings carry both byte length and codepoint count.  The carved
// Mach-O code only reads `data` and `u8_bytes`, never `codepoints`, so
// we set codepoints to u8_bytes (correct only for ASCII — fine for
// Mach-O symbol names, dylib paths, etc.; chalk does not validate
// UTF-8 on these).
// ============================================================================

n00b_string_t *
n00b_string_from_cstr(const char *s)
{
    size_t len = s ? strlen(s) : 0;
    return n00b_string_from_raw(s, (int64_t)len);
}

n00b_string_t *
n00b_string_from_raw(const char *s, int64_t len)
{
    if (len < 0) {
        len = 0;
    }

    n00b_string_t *str = (n00b_string_t *)calloc(1, sizeof(*str));

    str->data       = (char *)calloc(1, (size_t)len + 1);
    str->u8_bytes   = (size_t)len;
    str->codepoints = (size_t)len;

    if (len > 0 && s) {
        memcpy(str->data, s, (size_t)len);
    }

    return str;
}

n00b_string_t *
n00b_string_empty(void)
{
    return n00b_string_from_raw("", 0);
}
