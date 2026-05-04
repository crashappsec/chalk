/**
 * @file gguf.c
 * @brief Implementation of chalk's GGUF codec.
 *
 * GGUF is a simple typed-KV-pair container; the parser walks the KV
 * section once to locate the `chalk.mark` pair (if any), the
 * `general.alignment` pair (if any), and the byte boundary of the KV
 * section.  Mutation rebuilds the file with `chalk.mark` set/removed
 * and the alignment padding recomputed for the new layout — adding a
 * KV pair shifts the data section start by a non-aligned amount, so
 * leaving the original padding in place would break tensor offsets.
 */
#include "gguf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern unsigned char *SHA256(const unsigned char *d, size_t n,
                              unsigned char *md);
#define CHALK_GGUF_SHA256_LEN 32

#define GGUF_MAGIC          "GGUF"
#define GGUF_HEADER_SIZE    24      // magic + version + tensor_count + kv_count
#define GGUF_DEFAULT_ALIGN  32

// GGUF value types (subset chalk needs to skip).
#define GGUF_TYPE_UINT8    0
#define GGUF_TYPE_INT8     1
#define GGUF_TYPE_UINT16   2
#define GGUF_TYPE_INT16    3
#define GGUF_TYPE_UINT32   4
#define GGUF_TYPE_INT32    5
#define GGUF_TYPE_FLOAT32  6
#define GGUF_TYPE_BOOL     7
#define GGUF_TYPE_STRING   8
#define GGUF_TYPE_ARRAY    9
#define GGUF_TYPE_UINT64  10
#define GGUF_TYPE_INT64   11
#define GGUF_TYPE_FLOAT64 12

#define CHALK_KV_KEY      "chalk.mark"
#define CHALK_KV_KEY_LEN  10
#define ALIGN_KV_KEY      "general.alignment"
#define ALIGN_KV_KEY_LEN  17

// Diagnostic sink.
__attribute__((weak))
void chalk_gguf_warn(const char *msg) {
    fprintf(stderr, "chalk_gguf: %s\n", msg);
}
extern void chalk_gguf_warn(const char *msg);

// =============================================================================
// Handle
// =============================================================================

struct chalk_gguf {
    uint8_t *bytes;
    size_t   length;
    size_t   capacity;

    uint32_t version;
    uint64_t tensor_count;
    uint64_t kv_count;

    size_t   kv_section_off;     // == GGUF_HEADER_SIZE
    size_t   kv_section_end;     // start of tensor info section
    size_t   tensor_info_end;    // start of alignment padding
    size_t   data_off;           // first byte of tensor data

    uint32_t alignment;          // typically 32

    // Located chalk.mark pair, if present.
    bool     has_chalk;
    size_t   chalk_kv_off;       // start of pair
    size_t   chalk_kv_size;      // end - start
};

// =============================================================================
// LE primitive readers
// =============================================================================

static inline uint32_t r_u32(const uint8_t *p) {
    return  (uint32_t)p[0]
          | ((uint32_t)p[1] << 8)
          | ((uint32_t)p[2] << 16)
          | ((uint32_t)p[3] << 24);
}

static inline uint64_t r_u64(const uint8_t *p) {
    return  (uint64_t)p[0]
          | ((uint64_t)p[1] << 8)
          | ((uint64_t)p[2] << 16)
          | ((uint64_t)p[3] << 24)
          | ((uint64_t)p[4] << 32)
          | ((uint64_t)p[5] << 40)
          | ((uint64_t)p[6] << 48)
          | ((uint64_t)p[7] << 56);
}

static inline void w_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static inline void w_u64(uint8_t *p, uint64_t v) {
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
    p[4] = (uint8_t)(v >> 32);
    p[5] = (uint8_t)(v >> 40);
    p[6] = (uint8_t)(v >> 48);
    p[7] = (uint8_t)(v >> 56);
}

// =============================================================================
// KV parsing
//
// Skip a single typed value at `*pos` within [base, end).  On success
// advances *pos past the value and returns true.
// =============================================================================

static bool skip_value(const uint8_t *base, size_t end,
                       size_t *pos, uint32_t type);

static bool skip_simple(size_t *pos, size_t end, size_t bytes) {
    if (*pos + bytes > end) {
        return false;
    }
    *pos += bytes;
    return true;
}

static bool skip_string(const uint8_t *base, size_t end, size_t *pos) {
    if (*pos + 8 > end) {
        return false;
    }
    uint64_t len = r_u64(base + *pos);
    *pos += 8;
    if (*pos + len < *pos || *pos + len > end) {
        return false;
    }
    *pos += (size_t)len;
    return true;
}

static bool skip_value(const uint8_t *base, size_t end,
                       size_t *pos, uint32_t type) {
    switch (type) {
    case GGUF_TYPE_UINT8:
    case GGUF_TYPE_INT8:
    case GGUF_TYPE_BOOL:
        return skip_simple(pos, end, 1);
    case GGUF_TYPE_UINT16:
    case GGUF_TYPE_INT16:
        return skip_simple(pos, end, 2);
    case GGUF_TYPE_UINT32:
    case GGUF_TYPE_INT32:
    case GGUF_TYPE_FLOAT32:
        return skip_simple(pos, end, 4);
    case GGUF_TYPE_UINT64:
    case GGUF_TYPE_INT64:
    case GGUF_TYPE_FLOAT64:
        return skip_simple(pos, end, 8);
    case GGUF_TYPE_STRING:
        return skip_string(base, end, pos);
    case GGUF_TYPE_ARRAY: {
        if (*pos + 4 + 8 > end) {
            return false;
        }
        uint32_t elem_type = r_u32(base + *pos);
        *pos += 4;
        uint64_t count = r_u64(base + *pos);
        *pos += 8;
        for (uint64_t i = 0; i < count; i++) {
            if (!skip_value(base, end, pos, elem_type)) {
                return false;
            }
        }
        return true;
    }
    default:
        return false;
    }
}

// Skip a tensor_info entry: name(string) + n_dims(u32) + n_dims*u64
// dims + type(u32) + offset(u64).
static bool skip_tensor_info(const uint8_t *base, size_t end, size_t *pos) {
    if (!skip_string(base, end, pos)) {
        return false;
    }
    if (*pos + 4 > end) {
        return false;
    }
    uint32_t n_dims = r_u32(base + *pos);
    *pos += 4;
    // n_dims is bounded in practice; defend against garbage.
    if (n_dims > 1024) {
        return false;
    }
    if (*pos + (size_t)n_dims * 8 > end) {
        return false;
    }
    *pos += (size_t)n_dims * 8;
    if (*pos + 4 + 8 > end) {
        return false;
    }
    *pos += 4 + 8;  // dtype + offset
    return true;
}

// =============================================================================
// Parse / free
// =============================================================================

static size_t aligned_up(size_t v, uint32_t a) {
    if (a == 0) {
        return v;
    }
    return (v + a - 1) / a * a;
}

extern chalk_gguf_t *chalk_gguf_parse(const uint8_t *bytes, size_t length) {
    if (!bytes || length < GGUF_HEADER_SIZE) {
        return NULL;
    }
    if (memcmp(bytes, GGUF_MAGIC, 4) != 0) {
        return NULL;
    }
    uint32_t version      = r_u32(bytes + 4);
    uint64_t tensor_count = r_u64(bytes + 8);
    uint64_t kv_count     = r_u64(bytes + 16);
    if (version < 2 || version > 3) {
        return NULL;
    }

    chalk_gguf_t *g = calloc(1, sizeof(*g));
    if (!g) {
        return NULL;
    }
    g->bytes        = malloc(length);
    if (!g->bytes) {
        free(g);
        return NULL;
    }
    memcpy(g->bytes, bytes, length);
    g->length         = length;
    g->capacity       = length;
    g->version        = version;
    g->tensor_count   = tensor_count;
    g->kv_count       = kv_count;
    g->kv_section_off = GGUF_HEADER_SIZE;
    g->alignment      = GGUF_DEFAULT_ALIGN;
    g->has_chalk      = false;

    // Walk the KV section: locate boundary, chalk.mark, alignment.
    size_t pos = GGUF_HEADER_SIZE;
    for (uint64_t i = 0; i < kv_count; i++) {
        size_t pair_start = pos;

        if (pos + 8 > length) {
            chalk_gguf_free(g);
            return NULL;
        }
        uint64_t key_len = r_u64(g->bytes + pos);
        pos += 8;
        if (pos + key_len < pos || pos + key_len > length) {
            chalk_gguf_free(g);
            return NULL;
        }
        bool is_chalk_key =
            (key_len == CHALK_KV_KEY_LEN)
            && memcmp(g->bytes + pos, CHALK_KV_KEY, CHALK_KV_KEY_LEN) == 0;
        bool is_align_key =
            (key_len == ALIGN_KV_KEY_LEN)
            && memcmp(g->bytes + pos, ALIGN_KV_KEY, ALIGN_KV_KEY_LEN) == 0;
        pos += (size_t)key_len;

        if (pos + 4 > length) {
            chalk_gguf_free(g);
            return NULL;
        }
        uint32_t vtype = r_u32(g->bytes + pos);
        pos += 4;

        size_t value_start = pos;

        if (!skip_value(g->bytes, length, &pos, vtype)) {
            chalk_gguf_free(g);
            return NULL;
        }

        if (is_chalk_key) {
            if (vtype != GGUF_TYPE_STRING) {
                chalk_gguf_warn("chalk.mark KV is not a string; ignoring");
            } else {
                g->has_chalk     = true;
                g->chalk_kv_off  = pair_start;
                g->chalk_kv_size = pos - pair_start;
            }
        }
        if (is_align_key && vtype == GGUF_TYPE_UINT32) {
            uint32_t a = r_u32(g->bytes + value_start);
            if (a > 0 && a <= (1U << 30)) {
                g->alignment = a;
            }
        }
    }
    g->kv_section_end = pos;

    // Walk tensor info.
    for (uint64_t i = 0; i < tensor_count; i++) {
        if (!skip_tensor_info(g->bytes, length, &pos)) {
            chalk_gguf_free(g);
            return NULL;
        }
    }
    g->tensor_info_end = pos;

    // Tensor data starts at the first multiple of `alignment` at or
    // after tensor_info_end.
    g->data_off = aligned_up(pos, g->alignment);
    if (g->data_off > length) {
        // Padding spec said data starts past EOF; reject.
        chalk_gguf_free(g);
        return NULL;
    }

    return g;
}

extern void chalk_gguf_free(chalk_gguf_t *g) {
    if (!g) {
        return;
    }
    free(g->bytes);
    free(g);
}

// =============================================================================
// Read
// =============================================================================

extern const char *chalk_gguf_get_payload(chalk_gguf_t *g, size_t *out_size) {
    if (!g || !g->has_chalk) {
        return NULL;
    }
    // Pair layout: [u64 key_len][key bytes][u32 type][u64 val_len][val bytes]
    size_t off = g->chalk_kv_off;
    if (off + 8 > g->length) {
        return NULL;
    }
    uint64_t key_len = r_u64(g->bytes + off);
    off += 8 + (size_t)key_len + 4;  // skip key + type
    if (off + 8 > g->length) {
        return NULL;
    }
    uint64_t val_len = r_u64(g->bytes + off);
    off += 8;
    if (off + val_len < off || off + val_len > g->length) {
        return NULL;
    }
    if (out_size) {
        *out_size = (size_t)val_len;
    }
    return (const char *)(g->bytes + off);
}

// =============================================================================
// Mutation
// =============================================================================

// Build a fresh buffer with the supplied layout:
//   header (kv_count = new_kv_count, tensor_count unchanged, version
//   unchanged) || existing_kv_section (with optional chalk pair
//   removed) || optional new chalk pair || tensor_info ||
//   recomputed_padding || tensor_data
//
// `chalk_payload` may be NULL/0 to omit; otherwise a string KV pair
// for chalk.mark is appended at the end of the KV section (after
// other existing pairs) before tensor info.
static chalk_gguf_status_t rebuild(chalk_gguf_t *g,
                                   const char   *chalk_payload,
                                   size_t        chalk_payload_len) {
    // --- KV section (existing minus current chalk pair) ---
    size_t  src_kv_off  = g->kv_section_off;
    size_t  src_kv_end  = g->kv_section_end;
    size_t  src_kv_len  = src_kv_end - src_kv_off;
    size_t  hole_off    = g->has_chalk ? (g->chalk_kv_off  - src_kv_off) : 0;
    size_t  hole_len    = g->has_chalk ?  g->chalk_kv_size              : 0;
    size_t  base_kv_len = src_kv_len - hole_len;

    // --- New chalk pair size ---
    size_t  new_kv_pair_len = 0;
    if (chalk_payload != NULL) {
        // [u64 key_len][key][u32 type][u64 val_len][val]
        new_kv_pair_len = 8 + CHALK_KV_KEY_LEN + 4 + 8 + chalk_payload_len;
    }

    uint64_t new_kv_count = g->kv_count
                            - (g->has_chalk      ? 1 : 0)
                            + (chalk_payload != NULL ? 1 : 0);

    // --- Tensor info ---
    size_t   ti_len      = g->tensor_info_end - g->kv_section_end;

    // --- New layout offsets ---
    size_t   new_kv_section_end = GGUF_HEADER_SIZE + base_kv_len + new_kv_pair_len;
    size_t   new_ti_end         = new_kv_section_end + ti_len;
    size_t   new_data_off       = aligned_up(new_ti_end, g->alignment);
    size_t   pad_len            = new_data_off - new_ti_end;

    // --- Tensor data ---
    size_t   data_len = (g->length > g->data_off) ? (g->length - g->data_off) : 0;

    size_t   new_total = new_data_off + data_len;

    uint8_t *out = malloc(new_total);
    if (!out) {
        return CHALK_GGUF_ERR_INTERNAL;
    }

    // Header.
    memcpy(out, GGUF_MAGIC, 4);
    w_u32(out + 4,  g->version);
    w_u64(out + 8,  g->tensor_count);
    w_u64(out + 16, new_kv_count);

    // KV section minus existing chalk pair.
    size_t op = GGUF_HEADER_SIZE;
    if (hole_len == 0) {
        memcpy(out + op, g->bytes + src_kv_off, src_kv_len);
        op += src_kv_len;
    } else {
        // Bytes before the hole.
        memcpy(out + op, g->bytes + src_kv_off, hole_off);
        op += hole_off;
        // Bytes after the hole.
        size_t after_hole_off = src_kv_off + hole_off + hole_len;
        size_t after_hole_len = src_kv_end - after_hole_off;
        memcpy(out + op, g->bytes + after_hole_off, after_hole_len);
        op += after_hole_len;
    }

    // New chalk pair (string KV).
    if (chalk_payload != NULL) {
        w_u64(out + op, (uint64_t)CHALK_KV_KEY_LEN);
        op += 8;
        memcpy(out + op, CHALK_KV_KEY, CHALK_KV_KEY_LEN);
        op += CHALK_KV_KEY_LEN;
        w_u32(out + op, GGUF_TYPE_STRING);
        op += 4;
        w_u64(out + op, (uint64_t)chalk_payload_len);
        op += 8;
        if (chalk_payload_len) {
            memcpy(out + op, chalk_payload, chalk_payload_len);
            op += chalk_payload_len;
        }
    }

    // Tensor info.
    memcpy(out + op, g->bytes + g->kv_section_end, ti_len);
    op += ti_len;

    // Recomputed padding (zeroed).
    if (pad_len) {
        memset(out + op, 0, pad_len);
        op += pad_len;
    }

    // Tensor data.
    if (data_len) {
        memcpy(out + op, g->bytes + g->data_off, data_len);
        op += data_len;
    }

    if (op != new_total) {
        free(out);
        return CHALK_GGUF_ERR_INTERNAL;
    }

    // Replace handle's buffer and re-parse offsets.
    free(g->bytes);
    g->bytes        = out;
    g->length       = new_total;
    g->capacity     = new_total;
    g->kv_count     = new_kv_count;
    g->kv_section_end  = new_kv_section_end;
    g->tensor_info_end = new_ti_end;
    g->data_off        = new_data_off;
    g->has_chalk       = (chalk_payload != NULL);
    if (g->has_chalk) {
        // Recompute chalk pair location: it sits at the end of the KV
        // section (we appended it).
        g->chalk_kv_off  = new_kv_section_end - new_kv_pair_len;
        g->chalk_kv_size = new_kv_pair_len;
    } else {
        g->chalk_kv_off  = 0;
        g->chalk_kv_size = 0;
    }

    return CHALK_GGUF_OK;
}

extern chalk_gguf_status_t chalk_gguf_set_chalk(chalk_gguf_t *g,
                                                const char   *mark,
                                                size_t        mark_length) {
    if (!g || !mark) {
        return CHALK_GGUF_ERR_NULL;
    }
    return rebuild(g, mark, mark_length);
}

extern chalk_gguf_status_t chalk_gguf_remove_chalk(chalk_gguf_t *g) {
    if (!g) {
        return CHALK_GGUF_ERR_NULL;
    }
    if (!g->has_chalk) {
        return CHALK_GGUF_ERR_NO_CHALK;
    }
    return rebuild(g, NULL, 0);
}

extern const uint8_t *chalk_gguf_get_buffer(chalk_gguf_t *g, size_t *out_size) {
    if (!g) {
        return NULL;
    }
    if (out_size) {
        *out_size = g->length;
    }
    return g->bytes;
}

// =============================================================================
// Unchalked hash
// =============================================================================

extern chalk_gguf_status_t chalk_gguf_unchalked_hash(chalk_gguf_t *g,
                                                     char          out_hex[65]) {
    if (!g || !out_hex) {
        return CHALK_GGUF_ERR_NULL;
    }

    uint8_t *canon;
    size_t   canon_len;

    if (!g->has_chalk) {
        canon     = g->bytes;
        canon_len = g->length;
    } else {
        // Mirror rebuild() with chalk_payload = NULL.
        size_t  src_kv_off  = g->kv_section_off;
        size_t  src_kv_end  = g->kv_section_end;
        size_t  src_kv_len  = src_kv_end - src_kv_off;
        size_t  hole_off    = g->chalk_kv_off - src_kv_off;
        size_t  hole_len    = g->chalk_kv_size;
        size_t  base_kv_len = src_kv_len - hole_len;

        size_t  ti_len    = g->tensor_info_end - g->kv_section_end;
        size_t  new_kv_section_end = GGUF_HEADER_SIZE + base_kv_len;
        size_t  new_ti_end         = new_kv_section_end + ti_len;
        size_t  new_data_off       = aligned_up(new_ti_end, g->alignment);
        size_t  pad_len            = new_data_off - new_ti_end;
        size_t  data_len  = g->length > g->data_off ? g->length - g->data_off : 0;

        canon_len = new_data_off + data_len;
        canon     = malloc(canon_len);
        if (!canon) {
            return CHALK_GGUF_ERR_INTERNAL;
        }
        memcpy(canon, GGUF_MAGIC, 4);
        w_u32(canon + 4,  g->version);
        w_u64(canon + 8,  g->tensor_count);
        w_u64(canon + 16, g->kv_count - 1);

        size_t op = GGUF_HEADER_SIZE;
        memcpy(canon + op, g->bytes + src_kv_off, hole_off);
        op += hole_off;
        size_t after_off = src_kv_off + hole_off + hole_len;
        size_t after_len = src_kv_end - after_off;
        memcpy(canon + op, g->bytes + after_off, after_len);
        op += after_len;

        memcpy(canon + op, g->bytes + g->kv_section_end, ti_len);
        op += ti_len;
        if (pad_len) {
            memset(canon + op, 0, pad_len);
            op += pad_len;
        }
        if (data_len) {
            memcpy(canon + op, g->bytes + g->data_off, data_len);
        }
    }

    uint8_t digest[CHALK_GGUF_SHA256_LEN];
    SHA256(canon, canon_len, digest);
    if (canon != g->bytes) {
        free(canon);
    }

    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < CHALK_GGUF_SHA256_LEN; i++) {
        out_hex[i * 2]     = hex[digest[i] >> 4];
        out_hex[i * 2 + 1] = hex[digest[i] & 0xf];
    }
    out_hex[64] = '\0';
    return CHALK_GGUF_OK;
}
