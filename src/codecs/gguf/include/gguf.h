/**
 * @file gguf.h
 * @brief Chalk's GGUF codec — parse, mark, extract.
 *
 * GGUF layout
 * (https://github.com/ggerganov/ggml/blob/master/docs/gguf.md):
 *
 *     [4B "GGUF"][u32 version][u64 tensor_count][u64 kv_count]
 *     [kv_count KV pairs]
 *     [tensor_count tensor_info entries]
 *     [alignment padding]
 *     [tensor data]
 *
 * Tensor `offset` fields are relative to the data section start, so
 * adding a KV pair is safe as long as the alignment padding is
 * recomputed: the data section start shifts as a unit and the
 * relative offsets stay valid.
 *
 * Chalk inserts a string KV pair `chalk.mark` whose value is the
 * mark JSON.  v2 and v3 are supported; v1 is refused.
 *
 * The unchalked hash is the SHA-256 of the canonical form: header
 * with `kv_count - 1`, KV pairs with `chalk.mark` removed, tensor
 * info unchanged, padding recomputed, tensor data unchanged.  Stable
 * across remarks with payloads of any length.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// ============================================================================
// Status codes
// ============================================================================

typedef enum {
    CHALK_GGUF_OK              =  0,
    CHALK_GGUF_ERR_NULL        = -1,  ///< NULL handle.
    CHALK_GGUF_ERR_TRUNCATED   = -2,  ///< Truncated header / KV / tensor info.
    CHALK_GGUF_ERR_BAD_MAGIC   = -3,  ///< First 4 bytes != "GGUF".
    CHALK_GGUF_ERR_BAD_VERSION = -4,  ///< Version not in [2, 3].
    CHALK_GGUF_ERR_BAD_KV      = -5,  ///< KV section parse failed.
    CHALK_GGUF_ERR_NO_CHALK    = -6,  ///< remove: nothing to do.
    CHALK_GGUF_ERR_INTERNAL    = -7,
} chalk_gguf_status_t;

// ============================================================================
// Opaque handle
// ============================================================================

typedef struct chalk_gguf chalk_gguf_t;

/**
 * @brief Parse a GGUF file from raw bytes.
 *
 * The codec takes its own copy of `bytes`.  Subsequent mutation
 * operates on the internal copy.
 *
 * @return Owned handle (free with chalk_gguf_free), or NULL on parse
 *         failure (truncated, bad magic, unsupported version,
 *         malformed KV section).
 */
extern chalk_gguf_t *chalk_gguf_parse(const uint8_t *bytes, size_t length);

/// Release a handle.  NULL-safe.
extern void chalk_gguf_free(chalk_gguf_t *g);

// ============================================================================
// Read API
// ============================================================================

/**
 * @brief Return the chalk mark payload, or NULL if absent.
 *
 * The returned pointer aliases the handle's internal buffer; callers
 * MUST NOT free it and MUST NOT use it after chalk_gguf_free.  No
 * NUL terminator is appended; use `out_size`.
 */
extern const char *chalk_gguf_get_payload(chalk_gguf_t *g, size_t *out_size);

// ============================================================================
// Mutation API
// ============================================================================

/**
 * @brief Insert or replace the `chalk.mark` KV pair.
 *
 * On success the handle's internal buffer reflects the mutated file
 * with alignment padding recomputed.
 *
 * @param g            Parsed handle.
 * @param mark         Mark bytes (no quoting; stored verbatim as the
 *                     KV value).
 * @param mark_length  Mark byte length.
 * @return CHALK_GGUF_OK or CHALK_GGUF_ERR_*.
 */
extern chalk_gguf_status_t chalk_gguf_set_chalk(chalk_gguf_t *g,
                                                const char   *mark,
                                                size_t        mark_length);

/**
 * @brief Remove the `chalk.mark` KV pair (and recompute padding).
 *
 * @return CHALK_GGUF_OK on removal, CHALK_GGUF_ERR_NO_CHALK if absent.
 */
extern chalk_gguf_status_t chalk_gguf_remove_chalk(chalk_gguf_t *g);

/**
 * @brief Retrieve the (possibly mutated) raw bytes for write-back.
 *
 * The pointer aliases the handle; lifetime ends with chalk_gguf_free.
 */
extern const uint8_t *chalk_gguf_get_buffer(chalk_gguf_t *g, size_t *out_size);

// ============================================================================
// Unchalked hash
// ============================================================================

/**
 * @brief Compute the unchalked SHA-256 of the file in canonical form.
 *
 * Canonical form: KV section with `chalk.mark` removed, kv_count
 * decremented, padding recomputed for the resulting layout.  Stable
 * across remarks.  If no chalk mark is present, equals the natural
 * file SHA-256.
 *
 * @param out_hex  Caller-provided ≥65-byte buffer; receives 64 hex
 *                 chars + NUL on success.
 */
extern chalk_gguf_status_t chalk_gguf_unchalked_hash(chalk_gguf_t *g,
                                                     char          out_hex[65]);

// ============================================================================
// Diagnostics
//
// chalk_gguf_warn(const char *msg) is the diagnostic sink.  Default
// implementation lives in gguf.c (weak fprintf-to-stderr); the nim
// FFI wrapper provides a strong override at link time.
// ============================================================================
