/**
 * @file safetensors.c
 * @brief Implementation of chalk's SafeTensors codec.
 *
 * Hand-rolled JSON scanner over the file header — the codec needs only
 * structural location of the `__metadata__.chalk` key/value pair, not
 * a full JSON model.  Strings, escapes, and nested objects are scanned
 * properly so that a tensor name happening to contain `__metadata__`
 * or `chalk` cannot hijack the search.
 */
#include "safetensors.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// libcrypto via the static link wired in chalk's config.nims.
extern unsigned char *SHA256(const unsigned char *d, size_t n,
                              unsigned char *md);
#define CHALK_ST_SHA256_DIGEST_LEN 32

#define CHALK_KEY      "chalk"
#define CHALK_KEY_LEN  5
#define META_KEY       "__metadata__"
#define META_KEY_LEN   12

#define MAX_HEADER_SIZE  (100ULL * 1024ULL * 1024ULL)  // 100 MB sanity cap

// Diagnostic sink — weak default; the nim FFI overrides at link time.
__attribute__((weak))
void chalk_st_warn(const char *msg) {
    fprintf(stderr, "chalk_st: %s\n", msg);
}
extern void chalk_st_warn(const char *msg);

// =============================================================================
// Handle
// =============================================================================

struct chalk_st {
    uint8_t *bytes;       // owned
    size_t   length;
    size_t   capacity;
    uint64_t header_size; // value of the leading u64 LE
};

// =============================================================================
// Small helpers
// =============================================================================

static inline uint64_t read_u64_le(const uint8_t *p) {
    return  (uint64_t)p[0]
          | ((uint64_t)p[1] << 8)
          | ((uint64_t)p[2] << 16)
          | ((uint64_t)p[3] << 24)
          | ((uint64_t)p[4] << 32)
          | ((uint64_t)p[5] << 40)
          | ((uint64_t)p[6] << 48)
          | ((uint64_t)p[7] << 56);
}

static inline void write_u64_le(uint8_t *p, uint64_t v) {
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
// JSON scanner
//
// All scanning operates on [p, end).  Returns one-past-the-token or
// NULL on syntax error.
// =============================================================================

static const char *skip_ws(const char *p, const char *end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) {
        p++;
    }
    return p;
}

// Skip a JSON string literal.  p points at the opening '"'.
static const char *skip_str(const char *p, const char *end) {
    if (p >= end || *p != '"') {
        return NULL;
    }
    p++;
    while (p < end) {
        char c = *p;
        if (c == '\\') {
            if (p + 1 >= end) {
                return NULL;
            }
            p += 2;
            continue;
        }
        if (c == '"') {
            return p + 1;
        }
        p++;
    }
    return NULL;
}

static const char *skip_value(const char *p, const char *end);

// Skip a JSON object.  p points at the opening '{'.
static const char *skip_object(const char *p, const char *end) {
    if (p >= end || *p != '{') {
        return NULL;
    }
    p++;
    p = skip_ws(p, end);
    if (p < end && *p == '}') {
        return p + 1;
    }
    while (p < end) {
        p = skip_str(p, end);
        if (!p) {
            return NULL;
        }
        p = skip_ws(p, end);
        if (p >= end || *p != ':') {
            return NULL;
        }
        p++;
        p = skip_ws(p, end);
        p = skip_value(p, end);
        if (!p) {
            return NULL;
        }
        p = skip_ws(p, end);
        if (p >= end) {
            return NULL;
        }
        if (*p == ',') {
            p++;
            p = skip_ws(p, end);
            continue;
        }
        if (*p == '}') {
            return p + 1;
        }
        return NULL;
    }
    return NULL;
}

// Skip a JSON array.  p points at the opening '['.
static const char *skip_array(const char *p, const char *end) {
    if (p >= end || *p != '[') {
        return NULL;
    }
    p++;
    p = skip_ws(p, end);
    if (p < end && *p == ']') {
        return p + 1;
    }
    while (p < end) {
        p = skip_value(p, end);
        if (!p) {
            return NULL;
        }
        p = skip_ws(p, end);
        if (p >= end) {
            return NULL;
        }
        if (*p == ',') {
            p++;
            p = skip_ws(p, end);
            continue;
        }
        if (*p == ']') {
            return p + 1;
        }
        return NULL;
    }
    return NULL;
}

static const char *skip_value(const char *p, const char *end) {
    if (p >= end) {
        return NULL;
    }
    char c = *p;
    if (c == '"') {
        return skip_str(p, end);
    }
    if (c == '{') {
        return skip_object(p, end);
    }
    if (c == '[') {
        return skip_array(p, end);
    }
    // Number, true, false, null — scan until terminator.
    while (p < end) {
        char ch = *p;
        if (ch == ',' || ch == '}' || ch == ']'
            || ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
            return p;
        }
        p++;
    }
    return p;
}

// =============================================================================
// Pair location
//
// Locate `key` within the top-level object that begins at `obj_start`
// (which must point at '{').  On hit:
//   *key_quote     — opening quote of the key
//   *value_start   — first byte of the value
//   *value_end     — one past the value
//   *removable_lo  — leading offset of the span to remove for unmark
//                    (covers a leading comma if the pair has one;
//                    otherwise points at the key quote)
//   *removable_hi  — trailing offset of the span to remove (covers a
//                    trailing comma if the pair has one; otherwise
//                    equals value_end after stripping trailing ws)
// Returns true if found.
// =============================================================================

static bool find_pair(const char  *obj_start,
                      const char  *obj_end,
                      const char  *key,
                      size_t       key_len,
                      const char **key_quote,
                      const char **value_start,
                      const char **value_end,
                      const char **removable_lo,
                      const char **removable_hi) {
    if (obj_start >= obj_end || *obj_start != '{') {
        return false;
    }
    const char *p = obj_start + 1;
    p = skip_ws(p, obj_end);
    if (p < obj_end && *p == '}') {
        return false;
    }

    // Track the previous comma (if any) and start of the current key,
    // so when we find a hit we know whether a leading comma exists.
    const char *prev_comma = NULL;

    while (p < obj_end) {
        const char *this_key = p;
        const char *after_key = skip_str(p, obj_end);
        if (!after_key) {
            return false;
        }

        // Compare key text — between this_key+1 and after_key-1.
        size_t this_key_len = (size_t)(after_key - this_key) - 2;
        bool   matches      = (this_key_len == key_len)
                              && memcmp(this_key + 1, key, key_len) == 0;

        p = skip_ws(after_key, obj_end);
        if (p >= obj_end || *p != ':') {
            return false;
        }
        p++;
        p = skip_ws(p, obj_end);
        const char *vstart = p;
        const char *vend   = skip_value(p, obj_end);
        if (!vend) {
            return false;
        }

        // Look ahead past whitespace to the next comma or close-brace.
        const char *after_v = skip_ws(vend, obj_end);
        if (after_v >= obj_end) {
            return false;
        }
        bool has_trailing_comma = (*after_v == ',');

        if (matches) {
            *key_quote   = this_key;
            *value_start = vstart;
            *value_end   = vend;
            // Removable span:
            // - If a trailing comma exists: [key_quote, after_v+1)
            //   so the next key takes the position naturally.
            // - Else if a leading comma exists: [prev_comma, vend) but
            //   trim trailing ws back so we don't strand whitespace
            //   before the closing brace.
            // - Else (sole pair, no commas): [key_quote, vend).
            if (has_trailing_comma) {
                *removable_lo = this_key;
                *removable_hi = after_v + 1;
            } else if (prev_comma) {
                *removable_lo = prev_comma;
                *removable_hi = vend;
            } else {
                *removable_lo = this_key;
                *removable_hi = vend;
            }
            return true;
        }

        if (!has_trailing_comma) {
            return false;
        }
        prev_comma = after_v;
        p = after_v + 1;
        p = skip_ws(p, obj_end);
    }
    return false;
}

// =============================================================================
// JSON unescape into caller buffer (returns NUL-terminated; out must
// be at least input length + 1).  Returns final length.
// =============================================================================

static size_t json_unescape(const char *in, size_t in_len, char *out) {
    size_t o = 0;
    for (size_t i = 0; i < in_len; i++) {
        char c = in[i];
        if (c == '\\' && i + 1 < in_len) {
            char n = in[i + 1];
            i++;
            switch (n) {
            case 'n':  out[o++] = '\n'; break;
            case 'r':  out[o++] = '\r'; break;
            case 't':  out[o++] = '\t'; break;
            case '"':  out[o++] = '"';  break;
            case '\\': out[o++] = '\\'; break;
            case '/':  out[o++] = '/';  break;
            case 'b':  out[o++] = '\b'; break;
            case 'f':  out[o++] = '\f'; break;
            case 'u':
                if (i + 4 < in_len) {
                    // Minimal UTF-8 encoder for BMP escapes.  Marks are
                    // ASCII JSON in practice; surrogate pairs are
                    // ignored (escape passed through literally).
                    unsigned int cp = 0;
                    bool ok = true;
                    for (int k = 1; k <= 4; k++) {
                        char h = in[i + k];
                        cp <<= 4;
                        if      (h >= '0' && h <= '9') cp |= (unsigned)(h - '0');
                        else if (h >= 'a' && h <= 'f') cp |= (unsigned)(h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') cp |= (unsigned)(h - 'A' + 10);
                        else { ok = false; break; }
                    }
                    if (!ok) {
                        out[o++] = '\\';
                        out[o++] = 'u';
                    } else {
                        i += 4;
                        if (cp < 0x80) {
                            out[o++] = (char)cp;
                        } else if (cp < 0x800) {
                            out[o++] = (char)(0xC0 | (cp >> 6));
                            out[o++] = (char)(0x80 | (cp & 0x3F));
                        } else {
                            out[o++] = (char)(0xE0 | (cp >> 12));
                            out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                            out[o++] = (char)(0x80 | (cp & 0x3F));
                        }
                    }
                } else {
                    out[o++] = '\\';
                    out[o++] = 'u';
                }
                break;
            default:
                out[o++] = n;
                break;
            }
        } else {
            out[o++] = c;
        }
    }
    out[o] = '\0';
    return o;
}

// JSON-escape into caller buffer.  Returns final length.  Caller must
// provide a buffer of at least 2*in_len bytes (worst case).
static size_t json_escape(const char *in, size_t in_len, char *out) {
    size_t o = 0;
    for (size_t i = 0; i < in_len; i++) {
        char c = in[i];
        switch (c) {
        case '"':  out[o++] = '\\'; out[o++] = '"';  break;
        case '\\': out[o++] = '\\'; out[o++] = '\\'; break;
        case '\n': out[o++] = '\\'; out[o++] = 'n';  break;
        case '\r': out[o++] = '\\'; out[o++] = 'r';  break;
        case '\t': out[o++] = '\\'; out[o++] = 't';  break;
        default:
            if ((unsigned char)c < 0x20) {
                o += (size_t)snprintf(out + o, 8, "\\u%04x", (unsigned)c);
            } else {
                out[o++] = c;
            }
        }
    }
    return o;
}

// =============================================================================
// Parse / free
// =============================================================================

extern chalk_st_t *chalk_st_parse(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 8) {
        return NULL;
    }
    uint64_t hsz = read_u64_le(bytes);
    if (hsz == 0 || hsz > MAX_HEADER_SIZE || hsz > length - 8) {
        return NULL;
    }

    // Header must parse as a JSON object.
    const char *hdr     = (const char *)bytes + 8;
    const char *hdr_end = hdr + hsz;
    const char *p       = skip_ws(hdr, hdr_end);
    if (p >= hdr_end || *p != '{') {
        return NULL;
    }
    const char *closed  = skip_object(p, hdr_end);
    if (!closed) {
        return NULL;
    }

    chalk_st_t *st = calloc(1, sizeof(*st));
    if (!st) {
        return NULL;
    }
    st->bytes = malloc(length);
    if (!st->bytes) {
        free(st);
        return NULL;
    }
    memcpy(st->bytes, bytes, length);
    st->length      = length;
    st->capacity    = length;
    st->header_size = hsz;
    return st;
}

extern void chalk_st_free(chalk_st_t *st) {
    if (!st) {
        return;
    }
    free(st->bytes);
    free(st);
}

// =============================================================================
// Read API
// =============================================================================

// Internal: locate __metadata__.chalk pair within st's header.
// Returns pointers in the *removable* form so the same helper backs
// both read and remove paths.
static bool locate_chalk(chalk_st_t  *st,
                         const char **value_start,
                         const char **value_end,
                         const char **rm_lo,
                         const char **rm_hi) {
    const char *hdr     = (const char *)st->bytes + 8;
    const char *hdr_end = hdr + st->header_size;
    const char *p       = skip_ws(hdr, hdr_end);
    if (p >= hdr_end || *p != '{') {
        return false;
    }

    const char *meta_key_quote, *meta_v_start, *meta_v_end;
    const char *meta_rm_lo, *meta_rm_hi;
    if (!find_pair(p, hdr_end, META_KEY, META_KEY_LEN,
                   &meta_key_quote, &meta_v_start, &meta_v_end,
                   &meta_rm_lo, &meta_rm_hi)) {
        return false;
    }
    if (meta_v_start >= meta_v_end || *meta_v_start != '{') {
        return false;
    }

    const char *ck_key_quote;
    return find_pair(meta_v_start, meta_v_end,
                     CHALK_KEY, CHALK_KEY_LEN,
                     &ck_key_quote, value_start, value_end,
                     rm_lo, rm_hi);
}

extern char *chalk_st_get_payload(chalk_st_t *st, size_t *out_size) {
    if (!st) {
        return NULL;
    }
    const char *vs, *ve, *rl, *rh;
    if (!locate_chalk(st, &vs, &ve, &rl, &rh)) {
        return NULL;
    }
    // value is a quoted JSON string: vs..ve includes both quotes.
    if (vs >= ve || *vs != '"' || *(ve - 1) != '"') {
        return NULL;
    }
    size_t in_len = (size_t)(ve - vs) - 2;
    char  *out    = malloc(in_len + 1);
    if (!out) {
        return NULL;
    }
    size_t n = json_unescape(vs + 1, in_len, out);
    if (out_size) {
        *out_size = n;
    }
    return out;
}

// =============================================================================
// Mutation
// =============================================================================

// Build a fresh buffer for st->bytes by replacing the header text.
// new_header_text + new_header_len describe the new header bytes.
// Tensor data is preserved verbatim from the old buffer.
static chalk_st_status_t replace_header(chalk_st_t *st,
                                        const char *new_header_text,
                                        size_t      new_header_len) {
    if (new_header_len > MAX_HEADER_SIZE) {
        return CHALK_ST_ERR_BAD_HEADER;
    }
    size_t   old_data_off = 8 + (size_t)st->header_size;
    if (old_data_off > st->length) {
        return CHALK_ST_ERR_INTERNAL;
    }
    size_t   data_len     = st->length - old_data_off;
    size_t   new_total    = 8 + new_header_len + data_len;

    uint8_t *fresh = malloc(new_total);
    if (!fresh) {
        return CHALK_ST_ERR_INTERNAL;
    }
    write_u64_le(fresh, (uint64_t)new_header_len);
    memcpy(fresh + 8, new_header_text, new_header_len);
    if (data_len) {
        memcpy(fresh + 8 + new_header_len,
               st->bytes + old_data_off, data_len);
    }
    free(st->bytes);
    st->bytes       = fresh;
    st->length      = new_total;
    st->capacity    = new_total;
    st->header_size = (uint64_t)new_header_len;
    return CHALK_ST_OK;
}

extern chalk_st_status_t chalk_st_set_chalk(chalk_st_t *st,
                                            const char *mark,
                                            size_t      mark_length) {
    if (!st || !mark) {
        return CHALK_ST_ERR_NULL;
    }
    const char *hdr     = (const char *)st->bytes + 8;
    const char *hdr_end = hdr + st->header_size;
    size_t      hdr_len = (size_t)st->header_size;

    // Escape the mark for JSON-string embedding.
    char  *escaped = malloc(mark_length * 2 + 1);
    if (!escaped) {
        return CHALK_ST_ERR_INTERNAL;
    }
    size_t escaped_len = json_escape(mark, mark_length, escaped);

    // Worst-case new header size: existing + the new pair (key+value+
    // separator) + a few bytes of slack for braces/comma when adding
    // __metadata__.
    size_t worst = hdr_len + escaped_len + 64;
    char  *out   = malloc(worst);
    if (!out) {
        free(escaped);
        return CHALK_ST_ERR_INTERNAL;
    }
    size_t op = 0;

    // 1. Existing chalk → replace the value in place.
    const char *cv_start, *cv_end, *crm_lo, *crm_hi;
    if (locate_chalk(st, &cv_start, &cv_end, &crm_lo, &crm_hi)) {
        size_t prefix_len = (size_t)(cv_start - hdr);
        memcpy(out + op, hdr, prefix_len);
        op += prefix_len;
        out[op++] = '"';
        memcpy(out + op, escaped, escaped_len);
        op += escaped_len;
        out[op++] = '"';
        size_t suffix_off = (size_t)(cv_end - hdr);
        memcpy(out + op, hdr + suffix_off, hdr_len - suffix_off);
        op += hdr_len - suffix_off;
        free(escaped);
        chalk_st_status_t st_ = replace_header(st, out, op);
        free(out);
        return st_;
    }

    // 2. No existing chalk.  Find or create __metadata__.
    const char *p = skip_ws(hdr, hdr_end);
    if (p >= hdr_end || *p != '{') {
        free(escaped);
        free(out);
        return CHALK_ST_ERR_NOT_OBJECT;
    }
    const char *mk, *mv_start, *mv_end, *mrm_lo, *mrm_hi;
    if (find_pair(p, hdr_end, META_KEY, META_KEY_LEN,
                  &mk, &mv_start, &mv_end, &mrm_lo, &mrm_hi)) {
        // __metadata__ exists.  Inject `,"chalk":"<escaped>"` just
        // before the closing '}' (or as the sole member if empty).
        if (mv_start >= mv_end || *mv_start != '{' || *(mv_end - 1) != '}') {
            free(escaped);
            free(out);
            return CHALK_ST_ERR_BAD_HEADER;
        }

        // Detect whether the inner object is empty (only whitespace
        // between '{' and '}').
        bool empty = true;
        for (const char *q = mv_start + 1; q < mv_end - 1; q++) {
            if (*q != ' ' && *q != '\t' && *q != '\n' && *q != '\r') {
                empty = false;
                break;
            }
        }

        size_t prefix_len = (size_t)(mv_end - 1 - hdr);
        memcpy(out + op, hdr, prefix_len);
        op += prefix_len;
        if (!empty) {
            out[op++] = ',';
        }
        op += (size_t)snprintf(out + op, worst - op,
                               "\"%s\":\"", CHALK_KEY);
        memcpy(out + op, escaped, escaped_len);
        op += escaped_len;
        out[op++] = '"';
        // Copy from the closing '}' of __metadata__ to end of header.
        size_t suffix_off = (size_t)(mv_end - 1 - hdr);
        memcpy(out + op, hdr + suffix_off, hdr_len - suffix_off);
        op += hdr_len - suffix_off;
    } else {
        // No __metadata__ — insert one at the start of the root
        // object.  Keeping the new key first reads the same JSON the
        // hand-rolled scanner finds on the next pass.
        if (*p != '{') {
            free(escaped);
            free(out);
            return CHALK_ST_ERR_NOT_OBJECT;
        }
        size_t lead_len = (size_t)(p - hdr) + 1;  // include '{'
        memcpy(out + op, hdr, lead_len);
        op += lead_len;

        // Detect whether root object is empty (no other keys).
        const char *q = skip_ws(p + 1, hdr_end);
        bool empty_root = (q < hdr_end && *q == '}');

        op += (size_t)snprintf(out + op, worst - op,
                               "\"%s\":{\"%s\":\"",
                               META_KEY, CHALK_KEY);
        memcpy(out + op, escaped, escaped_len);
        op += escaped_len;
        out[op++] = '"';
        out[op++] = '}';
        if (!empty_root) {
            out[op++] = ',';
        }
        size_t suffix_off = (size_t)(p - hdr) + 1;
        memcpy(out + op, hdr + suffix_off, hdr_len - suffix_off);
        op += hdr_len - suffix_off;
    }

    free(escaped);
    chalk_st_status_t r = replace_header(st, out, op);
    free(out);
    return r;
}

extern chalk_st_status_t chalk_st_remove_chalk(chalk_st_t *st) {
    if (!st) {
        return CHALK_ST_ERR_NULL;
    }
    const char *vs, *ve, *rl, *rh;
    if (!locate_chalk(st, &vs, &ve, &rl, &rh)) {
        return CHALK_ST_ERR_NO_CHALK;
    }
    const char *hdr     = (const char *)st->bytes + 8;
    size_t      hdr_len = (size_t)st->header_size;
    size_t      lo_off  = (size_t)(rl - hdr);
    size_t      hi_off  = (size_t)(rh - hdr);
    size_t      new_len = hdr_len - (hi_off - lo_off);
    char       *out     = malloc(new_len);
    if (!out) {
        return CHALK_ST_ERR_INTERNAL;
    }
    memcpy(out, hdr, lo_off);
    memcpy(out + lo_off, hdr + hi_off, hdr_len - hi_off);
    chalk_st_status_t r = replace_header(st, out, new_len);
    free(out);
    return r;
}

extern const uint8_t *chalk_st_get_buffer(chalk_st_t *st, size_t *out_size) {
    if (!st) {
        return NULL;
    }
    if (out_size) {
        *out_size = st->length;
    }
    return st->bytes;
}

// =============================================================================
// Unchalked hash
// =============================================================================

extern chalk_st_status_t chalk_st_unchalked_hash(chalk_st_t *st,
                                                 char        out_hex[65]) {
    if (!st || !out_hex) {
        return CHALK_ST_ERR_NULL;
    }

    const char *vs, *ve, *rl, *rh;
    bool        has_chalk = locate_chalk(st, &vs, &ve, &rl, &rh);

    // Build a single contiguous canonical buffer to feed to SHA256().
    // The libcrypto SHA256() wrapper takes one buffer; chunked
    // hashing needs the *_CTX functions which we'd have to declare
    // separately.  Canonical form is small (header + tensor data),
    // so a single allocation is fine.
    uint8_t *canon;
    size_t   canon_len;

    if (!has_chalk) {
        canon     = st->bytes;
        canon_len = st->length;
    } else {
        const char *hdr     = (const char *)st->bytes + 8;
        size_t      hdr_len = (size_t)st->header_size;
        size_t      lo_off  = (size_t)(rl - hdr);
        size_t      hi_off  = (size_t)(rh - hdr);
        size_t      new_hdr_len = hdr_len - (hi_off - lo_off);
        size_t      data_off    = 8 + hdr_len;
        size_t      data_len    = st->length > data_off
                                  ? st->length - data_off : 0;

        canon_len = 8 + new_hdr_len + data_len;
        canon     = malloc(canon_len);
        if (!canon) {
            return CHALK_ST_ERR_INTERNAL;
        }
        write_u64_le(canon, (uint64_t)new_hdr_len);
        memcpy(canon + 8, hdr, lo_off);
        if (hdr_len > hi_off) {
            memcpy(canon + 8 + lo_off, hdr + hi_off, hdr_len - hi_off);
        }
        if (data_len) {
            memcpy(canon + 8 + new_hdr_len,
                   st->bytes + data_off, data_len);
        }
    }

    uint8_t digest[CHALK_ST_SHA256_DIGEST_LEN];
    SHA256(canon, canon_len, digest);
    if (canon != st->bytes) {
        free(canon);
    }

    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < CHALK_ST_SHA256_DIGEST_LEN; i++) {
        out_hex[i * 2]     = hex[digest[i] >> 4];
        out_hex[i * 2 + 1] = hex[digest[i] & 0xf];
    }
    out_hex[64] = '\0';
    return CHALK_ST_OK;
}
