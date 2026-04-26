/**
 * @file n00b_shim.h
 * @brief Minimal n00b-compat surface for the carved Mach-O subset.
 *
 * The carved Mach-O parser/builder originally targeted the n00b runtime.
 * Chalk runs single-threaded and does not need n00b — this shim provides
 * just the symbols the carved code touches, backed by malloc/calloc with
 * no locking.  Implementations live in n00b_shim.c.
 */
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// ============================================================================
// Buffer
// ============================================================================

typedef struct n00b_buffer_t {
    char  *data;
    size_t byte_len;
    size_t alloc_len;
} n00b_buffer_t;

extern n00b_buffer_t *n00b_buffer_new(int64_t capacity);
extern n00b_buffer_t *n00b_buffer_from_bytes(char *bytes, int64_t len);
extern void           n00b_buffer_resize(n00b_buffer_t *buf, uint64_t new_sz);
extern int64_t        n00b_buffer_len(n00b_buffer_t *buf);

/// Free buf->data and zero the struct (does NOT free the struct
/// itself).  Kept for compat with the carved code; new callers
/// should prefer n00b_buffer_destroy.
extern void           n00b_buffer_free(n00b_buffer_t *buf);

/// Free buf->data AND the buffer struct.  NULL-safe.
extern void           n00b_buffer_destroy(n00b_buffer_t *buf);

// ============================================================================
// String
// ============================================================================

typedef struct n00b_string_t {
    char  *data;
    size_t u8_bytes;
    size_t codepoints;
} n00b_string_t;

extern n00b_string_t *n00b_string_from_cstr(const char *s);
extern n00b_string_t *n00b_string_from_raw(const char *s, int64_t len);
extern n00b_string_t *n00b_string_empty(void);

// ============================================================================
// Allocation
// ============================================================================

#define n00b_alloc(T)             ((T *)calloc(1, sizeof(T)))
#define n00b_alloc_array(T, n)    ((T *)calloc((size_t)(n), sizeof(T)))

// ============================================================================
// Result
//
// The carved code uses `n00b_result_t(T)` as a tagged union of "ok with
// value of type T" or "err with code".  We collapse the payload to a
// single `uint64_t` slot.  At store time we cast `val` through
// `uintptr_t`: for unsigned ints this zero-extends, for signed ints
// the int->uintptr_t conversion is "modulo 2^N" which sign-extends
// in bit pattern, for pointers it is the well-defined ptr->uintptr_t
// conversion, for bool it is 0 or 1.  At retrieval the receiving cast
// extracts the low N bits, which round-trip back to the original value
// in all cases on a 64-bit host.  Chalk's macOS targets are 64-bit
// little-endian (arm64 and x86_64) — this is well-defined there.
// ============================================================================

typedef struct {
    bool     is_err;
    int      err_code;
    uint64_t v;
} n00b_result_carrier_t;

#define n00b_result_t(T)        n00b_result_carrier_t

#define n00b_result_is_err(r)   ((r).is_err)
#define n00b_result_is_ok(r)    (!(r).is_err)
#define n00b_result_get_err(r)  ((r).err_code)
#define n00b_result_get(r)      ((r).v)

#define n00b_result_ok(T, val)                                            \
    ((n00b_result_carrier_t){                                             \
        .is_err = false,                                                  \
        .err_code = 0,                                                    \
        .v = (uint64_t)(uintptr_t)(val)                                   \
    })

#define n00b_result_err(T, code)                                          \
    ((n00b_result_carrier_t){.is_err = true, .err_code = (int)(code), .v = 0})
