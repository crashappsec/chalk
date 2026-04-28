/**
 * @file safetensors.h
 * @brief Chalk's SafeTensors codec — parse, mark, extract.
 *
 * SafeTensors layout (https://github.com/huggingface/safetensors):
 *
 *     [u64 LE header_size][JSON header bytes][tensor data bytes]
 *
 * Tensor `data_offsets` are relative to the data section start, so
 * the header may grow without breaking offsets.  Chalk inserts its
 * mark as a string value under `__metadata__.chalk`, creating
 * `__metadata__` if absent.
 *
 * The unchalked hash is the SHA-256 of the canonical form: the file
 * with the entire `chalk` key/value pair structurally removed from
 * `__metadata__` and `header_size` recomputed.  Stable across remarks
 * with payloads of any length.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// ============================================================================
// Status codes
// ============================================================================

typedef enum {
    CHALK_ST_OK              =  0,
    CHALK_ST_ERR_NULL        = -1,  ///< NULL handle.
    CHALK_ST_ERR_TRUNCATED   = -2,  ///< File shorter than minimum.
    CHALK_ST_ERR_BAD_HEADER  = -3,  ///< header_size implausible / parse fail.
    CHALK_ST_ERR_NOT_OBJECT  = -4,  ///< Header isn't a JSON object.
    CHALK_ST_ERR_NO_CHALK    = -5,  ///< remove_chalk: nothing to do.
    CHALK_ST_ERR_INTERNAL    = -6,
} chalk_st_status_t;

// ============================================================================
// Opaque handle
// ============================================================================

typedef struct chalk_st chalk_st_t;

/**
 * @brief Parse a SafeTensors file from raw bytes.
 *
 * The codec takes its own copy of `bytes` (caller may free or reuse
 * the input buffer immediately on return).  Subsequent
 * set/remove_chalk calls mutate the internal copy in place.
 *
 * @return Owned handle (free with chalk_st_free), or NULL on parse
 *         failure (truncated, bogus header_size, malformed JSON).
 */
extern chalk_st_t *chalk_st_parse(const uint8_t *bytes, size_t length);

/// Release a handle.  NULL-safe.
extern void chalk_st_free(chalk_st_t *st);

// ============================================================================
// Read API
// ============================================================================

/**
 * @brief Return the chalk mark payload, or NULL if absent.
 *
 * The returned pointer aliases the handle's internal buffer; callers
 * MUST NOT free it and MUST NOT use it after chalk_st_free.  The
 * payload bytes are JSON-unescaped from the header's string value.
 *
 * @param st        Parsed handle.
 * @param out_size  Receives payload byte length (excludes any
 *                  internal NUL terminator).
 * @return Pointer to caller-readable bytes, or NULL.
 */
extern char *chalk_st_get_payload(chalk_st_t *st, size_t *out_size);

// ============================================================================
// Mutation API
// ============================================================================

/**
 * @brief Insert or replace the chalk mark in the header.
 *
 * If `__metadata__` is absent, it is created with a single key
 * `chalk`.  If present without a `chalk` member, the member is
 * appended.  If `chalk` is already there, its value is replaced.
 * On success the handle's internal buffer reflects the mutated file.
 *
 * @param st           Parsed handle.
 * @param mark         Mark JSON bytes (no surrounding quotes; this
 *                     function escapes for embedding as a string
 *                     value).
 * @param mark_length  Mark byte length.
 * @return CHALK_ST_OK or CHALK_ST_ERR_*.
 */
extern chalk_st_status_t chalk_st_set_chalk(chalk_st_t    *st,
                                            const char    *mark,
                                            size_t         mark_length);

/**
 * @brief Remove the chalk mark, leaving `__metadata__` itself in
 *        place (possibly empty).
 *
 * @return CHALK_ST_OK on removal, CHALK_ST_ERR_NO_CHALK if absent,
 *         CHALK_ST_ERR_* otherwise.
 */
extern chalk_st_status_t chalk_st_remove_chalk(chalk_st_t *st);

/**
 * @brief Retrieve the (possibly mutated) raw bytes for write-back.
 *
 * The pointer aliases the handle; lifetime ends with chalk_st_free.
 */
extern const uint8_t *chalk_st_get_buffer(chalk_st_t *st, size_t *out_size);

// ============================================================================
// Unchalked hash
// ============================================================================

/**
 * @brief Compute the unchalked SHA-256 of the file in canonical form.
 *
 * Canonical form: header has the chalk key/value pair structurally
 * removed; header_size is recomputed; then SHA-256 of (header_size_le
 * || canonical_header || tensor_data).  Stable across remarks with
 * payloads of any length.  If no chalk mark is present, equals the
 * natural file SHA-256.
 *
 * @param st       Parsed handle (any chalk-state — pre, post, never).
 * @param out_hex  Caller-provided ≥65-byte buffer; receives 64 hex
 *                 chars + NUL on success.
 */
extern chalk_st_status_t chalk_st_unchalked_hash(chalk_st_t *st,
                                                 char        out_hex[65]);

// ============================================================================
// Diagnostics
//
// chalk_st_warn(const char *msg) is the diagnostic sink.  Default
// implementation lives in safetensors.c (weak fprintf-to-stderr); the
// nim FFI wrapper provides a strong override that routes into chalk's
// `warn` template at link time, mirroring the chalk_macho_warn
// convention.
// ============================================================================
