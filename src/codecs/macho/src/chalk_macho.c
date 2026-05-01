/**
 * @file chalk_macho.c
 * @brief Chalk LC_NOTE helpers — in-place file mutation.
 *
 * Mirrors the strategy of `src/plugins/elf.nim`: parse to find
 * offsets, splice raw bytes inside the binary's stream buffer, patch
 * a few header integer fields, and let the caller write the new
 * bytes back to disk.  No rebuild from parsed structs.
 *
 * Mutation operations leave bin's parsed structs (commands[],
 * segments[], etc.) STALE — callers reparse if they need to inspect
 * the modified binary.
 */

#include <stdio.h>
#include <string.h>
#include <stdarg.h>

#include "chalk_macho.h"
#include "macho_types.h"

// ============================================================================
// OpenSSL SHA-256 prototype
//
// chalk links libcrypto statically (see config.nims libs).  Headers
// aren't pulled in here — we just declare the one symbol we use.
// ============================================================================

extern unsigned char *SHA256(const unsigned char *d, size_t n,
                             unsigned char *md);

#define SHA256_DIGEST_LEN 32

// ============================================================================
// Diagnostics
//
// chalk_macho_warn is declared weak: nim glue replaces it at link
// time with a strong symbol that forwards to chalk's `warn` template.
// In standalone builds (smoke test, third-party callers) the default
// writes to stderr.  The symbol is private to this translation unit
// — it is NOT declared in chalk_macho.h to avoid clashing with the
// nim-emitted hidden-visibility definition during chalk's main build.
// ============================================================================

extern void chalk_macho_warn(const char *msg);

__attribute__((weak)) void
chalk_macho_warn(const char *msg)
{
    fprintf(stderr, "chalk_macho: %s\n", msg);
}

static void
warnf(const char *fmt, ...)
{
    char   *msg = NULL;
    va_list ap;

    va_start(ap, fmt);
    int n = vasprintf(&msg, fmt, ap);
    va_end(ap);

    if (n < 0 || !msg) {
        return;
    }

    chalk_macho_warn(msg);
    free(msg);
}

// ============================================================================
// Little-endian byte access
// ============================================================================

static inline uint32_t
le_u32(const uint8_t *p)
{
    return  (uint32_t)p[0]
        | ((uint32_t)p[1] <<  8)
        | ((uint32_t)p[2] << 16)
        | ((uint32_t)p[3] << 24);
}

static inline uint64_t
le_u64(const uint8_t *p)
{
    return  (uint64_t)p[0]
        | ((uint64_t)p[1] <<  8)
        | ((uint64_t)p[2] << 16)
        | ((uint64_t)p[3] << 24)
        | ((uint64_t)p[4] << 32)
        | ((uint64_t)p[5] << 40)
        | ((uint64_t)p[6] << 48)
        | ((uint64_t)p[7] << 56);
}

static inline void
set_le_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v       & 0xFF);
    p[1] = (uint8_t)(v >>  8 & 0xFF);
    p[2] = (uint8_t)(v >> 16 & 0xFF);
    p[3] = (uint8_t)(v >> 24 & 0xFF);
}

static inline void
set_le_u64(uint8_t *p, uint64_t v)
{
    set_le_u32(p,     (uint32_t)(v        & 0xFFFFFFFFu));
    set_le_u32(p + 4, (uint32_t)(v >> 32  & 0xFFFFFFFFu));
}

// ============================================================================
// Buffer in-place mutation primitives
//
// macho_buf_truncate_and_append: mirrors nim's `fileData[off] = data`
// semantics — total length becomes off + src_len, region [off..eof)
// of the original buffer is overwritten by `src`.  Grows the
// underlying allocation as needed.
//
// macho_buf_patch_u32/u64: little-endian write at offset, no resize.
// ============================================================================

static bool
buf_truncate_and_append(n00b_buffer_t *buf, size_t off,
                        const uint8_t *src, size_t src_len)
{
    if (!buf) {
        return false;
    }

    if (off > buf->byte_len) {
        warnf("buf_truncate_and_append: offset %zu past EOF %zu",
              off, buf->byte_len);
        return false;
    }

    size_t new_len = off + src_len;

    n00b_buffer_resize(buf, new_len);

    if (buf->byte_len < new_len) {
        warnf("buf_truncate_and_append: resize to %zu failed", new_len);
        return false;
    }

    if (src_len > 0 && src) {
        memcpy(buf->data + off, src, src_len);
    }

    return true;
}

static bool
buf_patch_u32(n00b_buffer_t *buf, size_t off, uint32_t val)
{
    if (!buf || off + 4 > buf->byte_len) {
        return false;
    }

    set_le_u32((uint8_t *)buf->data + off, val);
    return true;
}

// (u64 patch helper kept for symmetry — unused for now; uncomment if
// add_note needs it.)
//
// static bool
// buf_patch_u64(n00b_buffer_t *buf, size_t off, uint64_t val)
// {
//     if (!buf || off + 8 > buf->byte_len) {
//         return false;
//     }
//
//     set_le_u64((uint8_t *)buf->data + off, val);
//     return true;
// }

// ============================================================================
// Mach-O layout helpers
// ============================================================================

#define MACHO_HEADER_SIZE    32
#define MACHO_NOTE_CMD_SIZE  40

// File offsets (within the slice — caller adds bin->fat_offset to
// translate to absolute).
typedef struct {
    size_t header_off;     ///< Start of the mach_header_64.
    size_t lc_off;         ///< Start of load commands (header_off + 32).
    size_t lc_end;         ///< End of load commands (header_off + 32 + sizeofcmds).
    size_t first_section;  ///< Smallest section file offset > 0; SIZE_MAX if none.
} macho_layout_t;

// Offsets within an LC_SEGMENT_64 command's raw_data, relative to
// the start of the command (byte 0 is the cmd field).  segment_command_64
// layout: cmd(4) cmdsize(4) segname[16] vmaddr(8) vmsize(8) fileoff(8)
// filesize(8) maxprot(4) initprot(4) nsects(4) flags(4)
#define SEGCMD_SEGNAME    8
#define SEGCMD_VMADDR    24
#define SEGCMD_VMSIZE    32
#define SEGCMD_FILEOFF   40
#define SEGCMD_FILESIZE  48

// Forward declaration — defined further down with the rest of the
// command-walking helpers.
static size_t command_offset(macho_binary_t *bin, uint32_t index);

// Find an LC_SEGMENT_64 command by name.  Returns the index in
// bin->commands[], or -1 if absent.
static int
find_segment_index(macho_binary_t *bin, const char *segname)
{
    size_t want_len = strlen(segname);

    if (want_len > 16) {
        return -1;
    }

    for (uint32_t i = 0; i < bin->num_commands; i++) {
        macho_command_t *cmd = &bin->commands[i];

        if (cmd->cmd != LC_SEGMENT_64
            || !cmd->raw_data
            || cmd->raw_data->byte_len < SEGCMD_FILEOFF + 16) {
            continue;
        }

        const char *raw_segname = cmd->raw_data->data + SEGCMD_SEGNAME;

        if (memcmp(raw_segname, segname, want_len) == 0
            && (want_len == 16 || raw_segname[want_len] == '\0')) {
            return (int)i;
        }
    }

    return -1;
}

// Find the LC_CODE_SIGNATURE command index, or -1.
static int
find_code_signature_index(macho_binary_t *bin)
{
    for (uint32_t i = 0; i < bin->num_commands; i++) {
        if (bin->commands[i].cmd == LC_CODE_SIGNATURE) {
            return (int)i;
        }
    }

    return -1;
}

static void
compute_layout(macho_binary_t *bin, macho_layout_t *out)
{
    out->header_off    = bin->fat_offset;
    out->lc_off        = out->header_off + MACHO_HEADER_SIZE;
    out->lc_end        = out->lc_off + bin->header.sizeofcmds;
    out->first_section = SIZE_MAX;

    for (uint32_t i = 0; i < bin->num_segments; i++) {
        macho_segment_t *seg = &bin->segments[i];

        for (uint32_t j = 0; j < seg->nsects; j++) {
            uint32_t sec_off = seg->sections[j].offset;

            if (sec_off > 0) {
                size_t abs = bin->fat_offset + sec_off;

                if (abs < out->first_section) {
                    out->first_section = abs;
                }
            }
        }
    }
}

// Locate the chalk LC_NOTE command in bin->commands[].  Returns the
// index, or -1 if absent.
static int
find_chalk_command_index(macho_binary_t *bin)
{
    for (uint32_t i = 0; i < bin->num_commands; i++) {
        macho_command_t *cmd = &bin->commands[i];

        if (cmd->cmd != LC_NOTE) {
            continue;
        }

        if (!cmd->raw_data
            || (size_t)cmd->raw_data->byte_len < MACHO_NOTE_CMD_SIZE) {
            continue;
        }

        const uint8_t *raw   = (const uint8_t *)cmd->raw_data->data;
        const char    *owner = (const char *)(raw + 8);

        // owner is a 16-byte field, NUL-padded.  Compare the prefix
        // up to strlen(CHALK_MACHO_NOTE_OWNER), then require the rest
        // to be NUL.
        size_t want = strlen(CHALK_MACHO_NOTE_OWNER);

        if (want > 16 || memcmp(owner, CHALK_MACHO_NOTE_OWNER, want) != 0) {
            continue;
        }

        bool ok = true;

        for (size_t k = want; k < 16; k++) {
            if (owner[k] != '\0') {
                ok = false;
                break;
            }
        }

        if (ok) {
            return (int)i;
        }
    }

    return -1;
}

// Compute the LC region offset (within the binary's stream buffer)
// of the i-th command.  Walks commands[0..i-1] summing cmdsize.
static size_t
command_offset(macho_binary_t *bin, uint32_t index)
{
    size_t off = bin->fat_offset + MACHO_HEADER_SIZE;

    for (uint32_t i = 0; i < index && i < bin->num_commands; i++) {
        off += bin->commands[i].cmdsize;
    }

    return off;
}

// ============================================================================
// Read API
// ============================================================================

static bool
data_owner_is_chalk(const char data_owner[16])
{
    size_t want = strlen(CHALK_MACHO_NOTE_OWNER);

    if (want > 16 || memcmp(data_owner, CHALK_MACHO_NOTE_OWNER, want) != 0) {
        return false;
    }

    for (size_t i = want; i < 16; i++) {
        if (data_owner[i] != '\0') {
            return false;
        }
    }

    return true;
}

// ============================================================================
// chalk_macho_signature_kind
//
// LC_CODE_SIGNATURE points at an EmbeddedSignatureBlob in __LINKEDIT.
// Layout (all big-endian):
//   uint32 magic   = 0xfade0cc0  (CSMAGIC_EMBEDDED_SIGNATURE)
//   uint32 length  = total bytes of the SuperBlob
//   uint32 count   = number of sub-blob index entries
//   { uint32 type; uint32 offset; } x count
//
// We classify by walking the index table:
//   - CSSLOT_CODEDIRECTORY (type==0) only           → adhoc
//   - CSSLOT_SIGNATURESLOT (type==0x10000) present
//     with a non-trivial blob (>8 bytes blob hdr)   → real_cert
//   - magic mismatch / lengths inconsistent          → malformed
// ============================================================================

#define CSMAGIC_EMBEDDED_SIGNATURE  0xfade0cc0u
#define CSSLOT_CODEDIRECTORY        0u
#define CSSLOT_SIGNATURESLOT        0x10000u

static inline uint32_t
be_u32(const uint8_t *p)
{
    return  ((uint32_t)p[0] << 24)
        |  ((uint32_t)p[1] << 16)
        |  ((uint32_t)p[2] <<  8)
        |   (uint32_t)p[3];
}

chalk_macho_sig_kind_t
chalk_macho_signature_kind(macho_binary_t *bin)
{
    if (!bin || !bin->stream || !bin->stream->buf) {
        return CHALK_MACHO_SIG_NONE;
    }

    n00b_buffer_t *buf         = bin->stream->buf;
    int            sig_cmd_idx = -1;

    for (uint32_t i = 0; i < bin->num_commands; i++) {
        if (bin->commands[i].cmd == LC_CODE_SIGNATURE) {
            sig_cmd_idx = (int)i;
            break;
        }
    }

    if (sig_cmd_idx < 0) {
        return CHALK_MACHO_SIG_NONE;
    }

    macho_command_t *cmd = &bin->commands[sig_cmd_idx];

    if (!cmd->raw_data || cmd->raw_data->byte_len < 16) {
        return CHALK_MACHO_SIG_MALFORMED;
    }

    // linkedit_data_command layout, little-endian on disk for
    // chalk's targets:
    //   cmd(4) cmdsize(4) dataoff(4) datasize(4)
    const uint8_t *raw = (const uint8_t *)cmd->raw_data->data;
    uint32_t       dataoff;
    uint32_t       datasize;

    memcpy(&dataoff,  raw + 8,  4);
    memcpy(&datasize, raw + 12, 4);

    uint64_t abs_off = bin->fat_offset + dataoff;

    if (datasize < 12 || abs_off + 12 > buf->byte_len) {
        return CHALK_MACHO_SIG_MALFORMED;
    }

    const uint8_t *sb        = (const uint8_t *)buf->data + abs_off;
    uint32_t       sb_magic  = be_u32(sb);
    uint32_t       sb_length = be_u32(sb + 4);
    uint32_t       sb_count  = be_u32(sb + 8);

    if (sb_magic != CSMAGIC_EMBEDDED_SIGNATURE
        || sb_length > datasize
        || sb_length < 12 + (uint64_t)sb_count * 8) {
        return CHALK_MACHO_SIG_MALFORMED;
    }

    bool has_codedir  = false;
    bool has_real_sig = false;

    for (uint32_t i = 0; i < sb_count; i++) {
        const uint8_t *idx    = sb + 12 + i * 8;
        uint32_t       type   = be_u32(idx);
        uint32_t       offset = be_u32(idx + 4);

        if (offset >= sb_length) {
            return CHALK_MACHO_SIG_MALFORMED;
        }

        if (type == CSSLOT_CODEDIRECTORY) {
            has_codedir = true;
        }

        if (type == CSSLOT_SIGNATURESLOT) {
            if (offset + 8 > sb_length) {
                return CHALK_MACHO_SIG_MALFORMED;
            }

            uint32_t blob_len = be_u32(sb + offset + 4);

            if (blob_len > 8) {
                has_real_sig = true;
            }
        }
    }

    if (!has_codedir) {
        return CHALK_MACHO_SIG_MALFORMED;
    }

    return has_real_sig ? CHALK_MACHO_SIG_REAL_CERT : CHALK_MACHO_SIG_ADHOC;
}

chalk_macho_note_t *
chalk_macho_get_notes(macho_binary_t *bin, size_t *out_count)
{
    if (out_count) {
        *out_count = 0;
    }

    if (!bin || !out_count) {
        return NULL;
    }

    size_t count = 0;

    for (uint32_t i = 0; i < bin->num_commands; i++) {
        if (bin->commands[i].cmd == LC_NOTE) {
            count++;
        }
    }

    if (count == 0) {
        return NULL;
    }

    chalk_macho_note_t *notes = (chalk_macho_note_t *)calloc(
        count, sizeof(*notes));

    if (!notes) {
        return NULL;
    }

    size_t out_i = 0;

    for (uint32_t i = 0; i < bin->num_commands; i++) {
        macho_command_t *cmd = &bin->commands[i];

        if (cmd->cmd != LC_NOTE) {
            continue;
        }

        if (!cmd->raw_data
            || (size_t)cmd->raw_data->byte_len < MACHO_NOTE_CMD_SIZE) {
            continue;
        }

        const uint8_t      *raw = (const uint8_t *)cmd->raw_data->data;
        chalk_macho_note_t *n   = &notes[out_i++];

        memcpy(n->data_owner, raw + 8, 16);
        n->data_owner[16] = '\0';
        n->payload_offset = le_u64(raw + 24);
        n->payload_size   = le_u64(raw + 32);

        if (bin->stream && bin->stream->buf
            && n->payload_offset + n->payload_size
                <= (uint64_t)bin->stream->buf->byte_len) {
            n->payload = (uint8_t *)bin->stream->buf->data
                       + n->payload_offset;
        }
    }

    *out_count = out_i;

    if (out_i == 0) {
        free(notes);
        return NULL;
    }

    return notes;
}

uint8_t *
chalk_macho_get_chalk_payload(macho_binary_t *bin, size_t *out_size)
{
    if (out_size) {
        *out_size = 0;
    }

    if (!bin || !out_size) {
        return NULL;
    }

    size_t              count = 0;
    chalk_macho_note_t *notes = chalk_macho_get_notes(bin, &count);

    if (!notes) {
        return NULL;
    }

    uint8_t *payload = NULL;

    for (size_t i = 0; i < count; i++) {
        if (data_owner_is_chalk(notes[i].data_owner) && notes[i].payload) {
            payload = (uint8_t *)malloc(notes[i].payload_size);

            if (payload) {
                memcpy(payload, notes[i].payload, notes[i].payload_size);
                *out_size = notes[i].payload_size;
            }

            break;
        }
    }

    free(notes);
    return payload;
}

// ============================================================================
// chalk_macho_add_note
//
// Strategy:
//   1. Refuse fat (deferred).
//   2. If a chalk note already exists, REPLACE: patch its
//      offset/size to point at a fresh payload appended at EOF.
//      The existing 40-byte command stays in place.  Old payload
//      bytes leak into trailing junk — chalk's mark is small, so
//      this is fine in practice.
//   3. Otherwise INSERT: require slack between LC region end and
//      the first section's file offset (>= 40 bytes).  Build a new
//      LC region (existing LCs + new note_command), build new tail
//      (everything after old LC region + new payload at EOF), splice
//      via buf_truncate_and_append, patch ncmds and sizeofcmds.
// ============================================================================

static chalk_macho_status_t
add_note_replace_existing(macho_binary_t *bin, int cmd_idx,
                          const uint8_t *payload, size_t payload_size)
{
    n00b_buffer_t *buf = bin->stream->buf;

    // Append the new payload at EOF.
    size_t new_payload_off = buf->byte_len;

    if (!buf_truncate_and_append(buf, new_payload_off, payload, payload_size)) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // Patch the existing note_command's offset and size fields.
    size_t cmd_off = command_offset(bin, (uint32_t)cmd_idx);

    // note_command layout: cmd(4) cmdsize(4) data_owner[16] offset(8) size(8)
    // → offset field at cmd_off + 24, size field at cmd_off + 32.
    if (new_payload_off > UINT64_MAX) {
        return CHALK_MACHO_ERR_TOO_LARGE;
    }

    set_le_u64((uint8_t *)buf->data + cmd_off + 24, new_payload_off);
    set_le_u64((uint8_t *)buf->data + cmd_off + 32, payload_size);

    return CHALK_MACHO_OK;
}

static chalk_macho_status_t
add_note_insert(macho_binary_t *bin,
                const uint8_t *payload, size_t payload_size)
{
    n00b_buffer_t  *buf = bin->stream->buf;
    macho_layout_t  layout;

    compute_layout(bin, &layout);

    // Slack check: need 40 bytes between lc_end and first_section.
    if (layout.first_section < layout.lc_end + MACHO_NOTE_CMD_SIZE) {
        warnf("add_note: insufficient load-command slack "
              "(lc_end=%zu first_section=%zu need=%d) — "
              "fallback to wrapper codec",
              layout.lc_end, layout.first_section, MACHO_NOTE_CMD_SIZE);
        return CHALK_MACHO_ERR_NO_LC_SLACK;
    }

    uint64_t new_sizeofcmds = (uint64_t)bin->header.sizeofcmds
                            + MACHO_NOTE_CMD_SIZE;

    if (new_sizeofcmds > UINT32_MAX) {
        warnf("add_note: new sizeofcmds (%llu) exceeds UINT32_MAX",
              (unsigned long long)new_sizeofcmds);
        return CHALK_MACHO_ERR_TOO_LARGE;
    }

    // The payload must live INSIDE __LINKEDIT — Apple's codesign
    // refuses to sign a binary with trailing data past __LINKEDIT
    // ("main executable failed strict validation").  We append the
    // payload at the end of __LINKEDIT, grow __LINKEDIT.filesize
    // (and vmsize) to cover it, and let codesign add a fresh
    // signature blob past our payload — also inside __LINKEDIT.
    //
    // PRECONDITION: caller has stripped any existing signature via
    // chalk_macho_strip_signature() first.  The codec layer
    // (codecMacho.nim) does this automatically.  If a stale
    // LC_CODE_SIGNATURE is present here, our payload would land
    // inside the signature blob region, get clobbered by codesign,
    // and the resulting binary would fail --verify.
    int le_idx = find_segment_index(bin, "__LINKEDIT");

    if (le_idx < 0) {
        warnf("add_note: no __LINKEDIT segment");
        return CHALK_MACHO_ERR_INTERNAL;
    }

    size_t le_cmd_off  = command_offset(bin, (uint32_t)le_idx);
    uint64_t le_fileoff;
    uint64_t le_filesize;

    memcpy(&le_fileoff,  (uint8_t *)buf->data + le_cmd_off + SEGCMD_FILEOFF, 8);
    memcpy(&le_filesize, (uint8_t *)buf->data + le_cmd_off + SEGCMD_FILESIZE, 8);

    size_t new_payload_off = (size_t)(le_fileoff + le_filesize);

    if (find_code_signature_index(bin) >= 0) {
        warnf("add_note: LC_CODE_SIGNATURE present — caller must "
              "chalk_macho_strip_signature() before add_note");
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // The file should currently extend exactly to __LINKEDIT's end
    // (no trailing junk).  If it doesn't, fail loudly.
    if ((size_t)buf->byte_len != new_payload_off) {
        warnf("add_note: __LINKEDIT end (%zu) != EOF (%zu); refusing",
              new_payload_off, (size_t)buf->byte_len);
        return CHALK_MACHO_ERR_INTERNAL;
    }

    size_t lc_end = layout.lc_end;

    // Append the payload at __LINKEDIT's end (= current EOF).
    if (!buf_truncate_and_append(buf, new_payload_off, payload, payload_size)) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // Build the note_command in the LC slack at lc_end.
    uint8_t *note = (uint8_t *)buf->data + lc_end;

    memset(note, 0, MACHO_NOTE_CMD_SIZE);
    set_le_u32(note,     LC_NOTE);
    set_le_u32(note + 4, MACHO_NOTE_CMD_SIZE);

    size_t want = strlen(CHALK_MACHO_NOTE_OWNER);

    memcpy(note + 8, CHALK_MACHO_NOTE_OWNER, want < 16 ? want : 16);
    set_le_u64(note + 24, new_payload_off);
    set_le_u64(note + 32, payload_size);

    // Grow __LINKEDIT.filesize by payload_size, and bump vmsize to
    // cover (round to 16K page).
    uint64_t new_le_filesize = le_filesize + payload_size;
    uint64_t new_le_vmsize   = (new_le_filesize + 0x3FFF) & ~(uint64_t)0x3FFF;

    if (new_le_vmsize < 0x4000) {
        new_le_vmsize = 0x4000;
    }

    set_le_u64((uint8_t *)buf->data + le_cmd_off + SEGCMD_FILESIZE,
               new_le_filesize);
    set_le_u64((uint8_t *)buf->data + le_cmd_off + SEGCMD_VMSIZE,
               new_le_vmsize);

    // Patch the mach_header_64: ncmds (offset 16) += 1, sizeofcmds
    // (offset 20) += 40.
    if (!buf_patch_u32(buf, bin->fat_offset + 16,
                        bin->header.ncmds + 1)
        || !buf_patch_u32(buf, bin->fat_offset + 20,
                          (uint32_t)new_sizeofcmds)) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // Sync bin->commands[]: append the new LC_NOTE entry.  realloc
    // the array (we keep things simple and assume one extra slot is
    // ok — chalk's typical workflow does at most one add_note +
    // remove_note on a parsed binary).
    macho_command_t *grown = (macho_command_t *)realloc(
        bin->commands,
        (bin->num_commands + 1) * sizeof(macho_command_t));

    if (!grown) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    bin->commands = grown;

    macho_command_t *new_cmd = &bin->commands[bin->num_commands];

    new_cmd->cmd      = LC_NOTE;
    new_cmd->cmdsize  = MACHO_NOTE_CMD_SIZE;
    new_cmd->raw_data = n00b_buffer_from_bytes((char *)note,
                                                MACHO_NOTE_CMD_SIZE);

    if (!new_cmd->raw_data) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    bin->num_commands       += 1;
    bin->header.ncmds       += 1;
    bin->header.sizeofcmds  += MACHO_NOTE_CMD_SIZE;

    return CHALK_MACHO_OK;
}

// ============================================================================
// chalk_macho_strip_signature
//
// Steps:
//   1. Find LC_CODE_SIGNATURE.  If absent, return OK (no-op).
//   2. Read its dataoff/datasize.
//   3. Truncate the file at dataoff (drop the signature blob).
//   4. Shrink __LINKEDIT.filesize to (dataoff - __LINKEDIT.fileoff).
//   5. Shift later LCs up by sizeof(LC_CODE_SIGNATURE)=16 within the
//      LC region; zero the trailing 16 bytes (slack).
//   6. Patch ncmds -= 1, sizeofcmds -= 16.
// ============================================================================

chalk_macho_status_t
chalk_macho_strip_signature(macho_binary_t *bin)
{
    if (!bin) {
        return CHALK_MACHO_ERR_NULL_BINARY;
    }

    if (bin->is_fat) {
        warnf("strip_signature: fat Mach-O not yet supported");
        return CHALK_MACHO_ERR_FAT;
    }

    if (!bin->stream || !bin->stream->buf) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    int sig_idx = find_code_signature_index(bin);

    if (sig_idx < 0) {
        return CHALK_MACHO_OK;  // nothing to do
    }

    n00b_buffer_t *buf = bin->stream->buf;

    // Read dataoff/datasize from the LC's raw_data.  linkedit_data_command
    // layout: cmd(4) cmdsize(4) dataoff(4) datasize(4) — total 16 bytes.
    macho_command_t *sig_cmd = &bin->commands[sig_idx];

    if (!sig_cmd->raw_data || sig_cmd->raw_data->byte_len < 16
        || sig_cmd->cmdsize != 16) {
        return CHALK_MACHO_ERR_BAD_NOTE;
    }

    uint32_t sig_dataoff;
    uint32_t sig_datasize;

    memcpy(&sig_dataoff,  (const uint8_t *)sig_cmd->raw_data->data + 8,  4);
    memcpy(&sig_datasize, (const uint8_t *)sig_cmd->raw_data->data + 12, 4);

    uint64_t abs_dataoff = bin->fat_offset + sig_dataoff;

    if (abs_dataoff > buf->byte_len) {
        return CHALK_MACHO_ERR_BAD_NOTE;
    }

    // Step 1: truncate the file at the signature data offset.
    buf->byte_len = (size_t)abs_dataoff;

    // Step 2: shrink __LINKEDIT.filesize to (sig_dataoff - le_fileoff).
    int le_idx = find_segment_index(bin, "__LINKEDIT");

    if (le_idx >= 0) {
        size_t   le_cmd_off = command_offset(bin, (uint32_t)le_idx);
        uint64_t le_fileoff;

        memcpy(&le_fileoff,
               (uint8_t *)buf->data + le_cmd_off + SEGCMD_FILEOFF, 8);

        if (sig_dataoff > le_fileoff) {
            uint64_t new_le_filesize = sig_dataoff - le_fileoff;

            set_le_u64((uint8_t *)buf->data + le_cmd_off + SEGCMD_FILESIZE,
                       new_le_filesize);
        }
    }

    // Step 3: remove the LC_CODE_SIGNATURE LC entry — shift later
    // LCs up within the LC region.  LC entries past `sig_idx` start
    // at sig_cmd_off + 16; they need to slide up by 16 bytes.
    size_t old_lc_end  = bin->fat_offset + MACHO_HEADER_SIZE
                       + bin->header.sizeofcmds;
    size_t sig_cmd_off = command_offset(bin, (uint32_t)sig_idx);
    size_t after       = sig_cmd_off + 16;
    size_t shift_len   = old_lc_end - after;

    if (shift_len > 0) {
        memmove((uint8_t *)buf->data + sig_cmd_off,
                (uint8_t *)buf->data + after,
                shift_len);
    }

    // Zero the trailing 16 bytes that are now slack.
    memset((uint8_t *)buf->data + old_lc_end - 16, 0, 16);

    // Step 4: patch header.
    if (!buf_patch_u32(buf, bin->fat_offset + 16, bin->header.ncmds - 1)
        || !buf_patch_u32(buf, bin->fat_offset + 20,
                           bin->header.sizeofcmds - 16)) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // Step 5: keep bin->commands[] in sync with the rewritten buffer.
    // Free the LC_CODE_SIGNATURE's raw_data, shift later entries
    // down by one, decrement num_commands, update bin->header.
    n00b_buffer_destroy(bin->commands[sig_idx].raw_data);

    if ((uint32_t)sig_idx + 1 < bin->num_commands) {
        memmove(&bin->commands[sig_idx],
                &bin->commands[sig_idx + 1],
                ((size_t)bin->num_commands - sig_idx - 1)
                  * sizeof(macho_command_t));
    }

    // Zero the now-vacated last slot.
    bin->commands[bin->num_commands - 1].cmd      = 0;
    bin->commands[bin->num_commands - 1].cmdsize  = 0;
    bin->commands[bin->num_commands - 1].raw_data = NULL;

    bin->num_commands       -= 1;
    bin->header.ncmds       -= 1;
    bin->header.sizeofcmds  -= 16;

    (void)sig_datasize;
    return CHALK_MACHO_OK;
}

chalk_macho_status_t
chalk_macho_add_note(macho_binary_t *bin,
                     const uint8_t *payload, size_t payload_size)
{
    if (!bin) {
        return CHALK_MACHO_ERR_NULL_BINARY;
    }

    if (bin->is_fat) {
        warnf("add_note: fat Mach-O not yet supported — "
              "fallback to wrapper codec");
        return CHALK_MACHO_ERR_FAT;
    }

    if (!bin->stream || !bin->stream->buf) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // If a chalk note is already present, remove it first.  This is
    // cleaner than a "patch in place" path because the new payload
    // size may differ from the old, and the in-LINKEDIT layout makes
    // patch-in-place expensive.
    if (find_chalk_command_index(bin) >= 0) {
        chalk_macho_status_t st = chalk_macho_remove_note(bin);
        if (st != CHALK_MACHO_OK) {
            return st;
        }
    }

    return add_note_insert(bin, payload, payload_size);
}

// ============================================================================
// chalk_macho_remove_note
//
// Reverse of add_note:
//   1. Truncate the chalk payload bytes from __LINKEDIT (caller of
//      remove_note must have stripped any signature first, so the
//      payload is at the end of __LINKEDIT and not buried under a
//      sig blob).
//   2. Shrink __LINKEDIT.filesize by payload_size.
//   3. Shift later LCs up by 40 within the LC region; zero the
//      trailing 40 bytes (slack).
//   4. Patch ncmds -= 1, sizeofcmds -= 40.
//   5. Update bin->commands[] in sync with the buffer.
//
// PRECONDITION: caller has stripped the existing signature first.
// If the chalk payload is not exactly at __LINKEDIT-end (e.g. the
// binary still has its signature blob), we still strip the LC entry
// but leave the payload bytes alone (becomes trailing junk).
// ============================================================================

chalk_macho_status_t
chalk_macho_remove_note(macho_binary_t *bin)
{
    if (!bin) {
        return CHALK_MACHO_ERR_NULL_BINARY;
    }

    if (bin->is_fat) {
        warnf("remove_note: fat Mach-O not yet supported");
        return CHALK_MACHO_ERR_FAT;
    }

    if (!bin->stream || !bin->stream->buf) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    int idx = find_chalk_command_index(bin);

    if (idx < 0) {
        return CHALK_MACHO_ERR_NO_CHALK_NOTE;
    }

    n00b_buffer_t   *buf      = bin->stream->buf;
    macho_command_t *chalk_cmd = &bin->commands[idx];
    size_t           cmd_off  = command_offset(bin, (uint32_t)idx);
    size_t           old_lc_end = bin->fat_offset + MACHO_HEADER_SIZE
                                + bin->header.sizeofcmds;

    if (cmd_off + MACHO_NOTE_CMD_SIZE > old_lc_end
        || old_lc_end > buf->byte_len) {
        return CHALK_MACHO_ERR_BAD_NOTE;
    }

    // Pull the payload's offset/size from the LC's raw_data.
    if (!chalk_cmd->raw_data
        || chalk_cmd->raw_data->byte_len < MACHO_NOTE_CMD_SIZE) {
        return CHALK_MACHO_ERR_BAD_NOTE;
    }

    const uint8_t *raw     = (const uint8_t *)chalk_cmd->raw_data->data;
    uint64_t       pay_off = le_u64(raw + 24);
    uint64_t       pay_sz  = le_u64(raw + 32);

    // Try to truncate the payload from __LINKEDIT if it's near the
    // segment's tail.  Even if there's some alignment padding after
    // it (codesign sometimes inserts a few bytes when growing the
    // signature blob past our payload), we still treat
    // [pay_off..__LINKEDIT-end] as drop-able: that range can only
    // contain our payload + alignment padding (any other LINKEDIT
    // data lives BEFORE pay_off by construction).
    int le_idx = find_segment_index(bin, "__LINKEDIT");

    if (le_idx >= 0) {
        size_t   le_cmd_off = command_offset(bin, (uint32_t)le_idx);
        uint64_t le_fileoff;
        uint64_t le_filesize;

        memcpy(&le_fileoff,
               (uint8_t *)buf->data + le_cmd_off + SEGCMD_FILEOFF, 8);
        memcpy(&le_filesize,
               (uint8_t *)buf->data + le_cmd_off + SEGCMD_FILESIZE, 8);

        uint64_t le_end = le_fileoff + le_filesize;

        if (pay_off >= le_fileoff
            && pay_off + pay_sz <= le_end
            && le_end == buf->byte_len) {
            // Drop everything from pay_off onward.
            buf->byte_len = (size_t)pay_off;

            uint64_t drop = le_end - pay_off;
            uint64_t new_le_filesize = le_filesize - drop;

            set_le_u64((uint8_t *)buf->data + le_cmd_off + SEGCMD_FILESIZE,
                       new_le_filesize);
        }
    }

    // Shift LCs after the chalk one up by 40 within the LC region.
    size_t after     = cmd_off + MACHO_NOTE_CMD_SIZE;
    size_t shift_len = old_lc_end - after;

    if (shift_len > 0) {
        memmove((uint8_t *)buf->data + cmd_off,
                (uint8_t *)buf->data + after,
                shift_len);
    }

    memset((uint8_t *)buf->data + old_lc_end - MACHO_NOTE_CMD_SIZE,
           0, MACHO_NOTE_CMD_SIZE);

    // Patch header.
    if (!buf_patch_u32(buf, bin->fat_offset + 16, bin->header.ncmds - 1)
        || !buf_patch_u32(buf, bin->fat_offset + 20,
                           bin->header.sizeofcmds - MACHO_NOTE_CMD_SIZE)) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // Sync bin->commands[].
    n00b_buffer_destroy(bin->commands[idx].raw_data);

    if ((uint32_t)idx + 1 < bin->num_commands) {
        memmove(&bin->commands[idx],
                &bin->commands[idx + 1],
                ((size_t)bin->num_commands - idx - 1)
                  * sizeof(macho_command_t));
    }

    bin->commands[bin->num_commands - 1].cmd      = 0;
    bin->commands[bin->num_commands - 1].cmdsize  = 0;
    bin->commands[bin->num_commands - 1].raw_data = NULL;
    bin->num_commands       -= 1;
    bin->header.ncmds       -= 1;
    bin->header.sizeofcmds  -= MACHO_NOTE_CMD_SIZE;

    return CHALK_MACHO_OK;
}

// ============================================================================
// chalk_macho_unchalked_hash
//
// Mirrors elf.nim:getUnchalkedHash semantics.  ELF's invariant: a
// marked binary and the same binary unmarked produce the SAME
// unchalked hash, because both are first canonicalized to "binary
// with a single 32-byte-zero-payload chalk-free section" before
// hashing.
//
// Mach-O analog: canonicalize to "binary with a single chalk LC_NOTE
// whose payload is exactly SHA256_DIGEST_LEN (32) zero bytes,"
// regardless of whether one was present, then SHA-256 the result.
// We compute this entirely on a scratch byte buffer without mutating
// bin's stream.
//
// Steps:
//   1. Materialize a clean unmarked copy of bin's bytes:
//        - if a chalk LC_NOTE is present in bin, splice it out of
//          the LC region and zero its payload bytes.  We don't
//          truncate any trailing payload (it'd require knowing the
//          payload was contiguous at EOF and not interleaved with
//          other data we care about).  Zeroing is enough — the
//          canonical-form add below produces the same payload
//          location and contents in both starting states.
//   2. Splice in a fresh 40-byte chalk LC_NOTE pointing at 32 zero
//      bytes appended at EOF.  Patch ncmds += 1, sizeofcmds += 40
//      from the values in the cleaned copy.
//   3. SHA-256 the canonical bytes; hex-encode.
//
// Edge cases the smoke test surfaces:
//   - If the marked binary's existing chalk payload was inserted by
//     us (always at EOF), then "splice out, append canonical 32-zero
//     payload" produces the same bytes as "insert canonical from
//     unmarked" on the equivalent baseline.
//   - If the existing chalk payload was injected by some other tool
//     somewhere weird (e.g. inside __LINKEDIT slack), zeroing the
//     bytes-at-payload-offset still produces a deterministic byte
//     pattern that re-marks will reproduce on the same starting
//     binary — so the hash is stable even if not byte-identical to
//     "unchalked-and-rechalked-canonical".
// ============================================================================

#define UNCHALKED_PAYLOAD_LEN  SHA256_DIGEST_LEN

static void
hex_encode(const uint8_t *src, size_t n, char *dst)
{
    static const char hex[] = "0123456789abcdef";

    for (size_t i = 0; i < n; i++) {
        dst[2 * i]     = hex[(src[i] >> 4) & 0x0F];
        dst[2 * i + 1] = hex[src[i] & 0x0F];
    }

    dst[2 * n] = '\0';
}

chalk_macho_status_t
chalk_macho_unchalked_hash(macho_binary_t *bin, char out_hex[65])
{
    if (!bin || !out_hex) {
        return CHALK_MACHO_ERR_NULL_BINARY;
    }

    if (!bin->stream || !bin->stream->buf) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    // Canonicalize the binary on a clone:
    //   1. Parse the bytes into a fresh macho_fat_t.
    //   2. Run strip_signature on it (drop linker-applied sig).
    //   3. Run add_note with a 32-byte zero payload (this also
    //      removes any existing chalk note and re-adds the canonical
    //      one — see chalk_macho_add_note).
    //   4. SHA-256 the resulting bytes.
    //   5. Free the clone.
    //
    // Both marked and unmarked starting states converge to the same
    // canonical layout: stripped signature, single canonical chalk
    // LC_NOTE pointing at 32 zero bytes at __LINKEDIT-end.  Hash
    // matches across mark / unmark / re-mark with any payload size.
    n00b_buffer_t *src  = bin->stream->buf;
    n00b_buffer_t *clone = n00b_buffer_from_bytes(src->data,
                                                  (int64_t)src->byte_len);

    if (!clone) {
        return CHALK_MACHO_ERR_INTERNAL;
    }

    macho_stream_t *clone_stream = macho_stream_new(clone);

    if (!clone_stream) {
        n00b_buffer_destroy(clone);
        return CHALK_MACHO_ERR_INTERNAL;
    }

    n00b_result_carrier_t pr = macho_parse(clone_stream);

    if (n00b_result_is_err(pr)) {
        macho_stream_free(clone_stream);
        return CHALK_MACHO_ERR_INTERNAL;
    }

    macho_fat_t    *clone_fat = (macho_fat_t *)pr.v;
    macho_binary_t *clone_bin = clone_fat->binaries[0];

    chalk_macho_status_t st = chalk_macho_strip_signature(clone_bin);

    if (st != CHALK_MACHO_OK) {
        chalk_macho_free(clone_fat);
        return st;
    }

    static const uint8_t kZeros[SHA256_DIGEST_LEN] = {0};

    st = chalk_macho_add_note(clone_bin, kZeros, SHA256_DIGEST_LEN);

    if (st != CHALK_MACHO_OK) {
        chalk_macho_free(clone_fat);
        return st;
    }

    n00b_buffer_t *out  = clone_bin->stream->buf;
    uint8_t        digest[SHA256_DIGEST_LEN];

    SHA256((const unsigned char *)out->data,
           out->byte_len, digest);

    chalk_macho_free(clone_fat);

    hex_encode(digest, SHA256_DIGEST_LEN, out_hex);
    return CHALK_MACHO_OK;
}

// ============================================================================
// chalk_macho_get_buffer
// ============================================================================

const uint8_t *
chalk_macho_get_buffer(macho_binary_t *bin, size_t *out_size)
{
    if (out_size) {
        *out_size = 0;
    }

    if (!bin || !bin->stream || !bin->stream->buf) {
        return NULL;
    }

    *out_size = bin->stream->buf->byte_len;
    return (const uint8_t *)bin->stream->buf->data;
}
