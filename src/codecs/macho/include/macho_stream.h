/**
 * @file macho_stream.h
 * @brief Tiny stream wrapper around a byte buffer.
 *
 * Trimmed from the original lief-c stream API (which had read/peek
 * helpers for u8..u64, sleb128, uleb128, cstrings, alignment, etc.).
 * The slim parser does direct memcpy reads against the raw buffer,
 * so this header just exposes constructors + the buffer pointer.
 */
#pragma once

#include "n00b_shim.h"
#include "macho_common.h"

struct macho_stream {
    n00b_buffer_t *buf;     ///< Owned: freed when the stream is freed.
    size_t         pos;     ///< Unused by the slim parser; kept zero.
    bool           swap_endian;
};

/// Wrap an existing buffer.  Buffer ownership transfers to the
/// stream — freeing the stream frees the buffer too.
extern macho_stream_t *macho_stream_new(n00b_buffer_t *buf);

/// Read a file into a fresh stream.  Owned by the caller (or by the
/// macho_fat_t once macho_parse takes it).
extern n00b_result_t(macho_stream_t *) macho_stream_from_file(
    const char *path);

/// Free a stream + its buffer + the buffer's data.  NULL-safe.
extern void macho_stream_free(macho_stream_t *s);
