/**
 * @file macho.c
 * @brief Slim Mach-O 64 parser focused on chalk's needs.
 *
 * Parses just enough of a Mach-O binary (thin or fat) to support
 * chalk's LC_NOTE-based marking:
 *
 *   - mach_header_64 fields
 *   - load command table (cmd / cmdsize / raw cmdsize bytes)
 *   - LC_SEGMENT_64 sub-parse: section count + each section's file
 *     offset (used for slack analysis)
 *   - fat magic detection + per-slice header offsets
 *
 * Does NOT parse: symbol table, dylibs, dyld_info opcodes,
 * binding/rebase/export tries, chained fixups, code signature deep
 * structure, build version, version-min, encryption-info,
 * data-in-code, fileset entries, linker options, rpaths,
 * dylinker path, indirect symbols, function starts, source version,
 * UUID, entrypoint, stack size.
 *
 * If chalk grows a need for any of those (e.g. real-cert detection
 * for `isOwnable`), parse them on demand from the raw cmd bytes
 * stored in `bin->commands[i].raw_data` rather than re-introducing
 * the deep upstream parser.
 */

#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "macho.h"
#include "macho_endian.h"

// ============================================================================
// Endianness — chalk's macOS targets are little-endian; the parser
// flips fields when the file's magic indicates the opposite.
// ============================================================================

static inline bool
host_is_little_endian(void)
{
    union {
        uint16_t u;
        uint8_t  b[2];
    } probe = {.u = 1};

    return probe.b[0] == 1;
}

// ============================================================================
// Bounds-checked little-endian byte reads against the stream buffer.
// ============================================================================

static bool
read_u32(n00b_buffer_t *buf, size_t off, bool swap, uint32_t *out)
{
    if (off + 4 > buf->byte_len) {
        return false;
    }

    uint32_t v;

    memcpy(&v, buf->data + off, 4);

    if (swap) {
        v = macho_swap32(v);
    }

    *out = v;
    return true;
}

// ============================================================================
// parse_header — fills bin->header and detects endian-swap from magic.
//
// Returns false on bounds violation or unsupported magic.  Sets
// `*swap` to true if the file is opposite-endian to the host.
// ============================================================================

static bool
parse_header(n00b_buffer_t *buf, size_t off,
             macho_header_t *out, bool *swap)
{
    if (off + MACHO64_HEADER_SIZE > buf->byte_len) {
        return false;
    }

    uint32_t magic;

    memcpy(&magic, buf->data + off, 4);

    bool host_le = host_is_little_endian();

    if (magic == MH_MAGIC_64) {
        *swap = !host_le;
    }
    else if (magic == MH_CIGAM_64) {
        *swap = host_le;
        magic = MH_MAGIC_64;
    }
    else {
        return false;
    }

    out->magic = magic;

    // Read remaining 7 u32 fields with the correct endianness.
    uint32_t fields[7];

    for (int i = 0; i < 7; i++) {
        if (!read_u32(buf, off + 4 + 4u * (uint32_t)i, *swap, &fields[i])) {
            return false;
        }
    }

    out->cputype    = fields[0];
    out->cpusubtype = fields[1];
    out->filetype   = fields[2];
    out->ncmds      = fields[3];
    out->sizeofcmds = fields[4];
    out->flags      = fields[5];
    out->reserved   = fields[6];
    return true;
}

// ============================================================================
// parse_segment_sections — fills seg->{nsects,sections[].offset}.
//
// LC_SEGMENT_64 layout (raw_data, after the 8-byte cmd/cmdsize):
//   segname[16]  vmaddr(8)  vmsize(8)  fileoff(8)  filesize(8)
//   maxprot(4)   initprot(4) nsects(4) flags(4)
// Total prefix = 16 + 8*4 + 4*4 = 64 bytes BEFORE the per-section table.
// Each section_64 entry = 80 bytes; offset field is at +48 (after
// sectname[16]+segname[16]+addr(8)+size(8) = 48 bytes).
// ============================================================================

#define SEG_PREFIX_SIZE     64u
#define SEC_ENTRY_SIZE      80u
#define SEC_OFFSET_FIELD    48u

static bool
parse_segment_sections(const uint8_t *raw, uint32_t cmdsize, bool swap,
                       macho_segment_t *seg)
{
    seg->nsects   = 0;
    seg->sections = NULL;

    // raw points at the start of the LC_SEGMENT_64 command (with
    // the 8-byte cmd/cmdsize header).  Fields below are offset from
    // there; nsects lives at +56.
    if (cmdsize < 8 + SEG_PREFIX_SIZE) {
        return false;
    }

    uint32_t nsects;

    memcpy(&nsects, raw + 8 + 56, 4);

    if (swap) {
        nsects = macho_swap32(nsects);
    }

    if (nsects == 0) {
        return true;
    }

    // Sanity: each section is 80 bytes; total must fit in cmdsize.
    if ((uint64_t)cmdsize < 8 + SEG_PREFIX_SIZE
                          + (uint64_t)nsects * SEC_ENTRY_SIZE) {
        return false;
    }

    seg->sections = (macho_section_t *)calloc(nsects,
                                              sizeof(macho_section_t));

    if (!seg->sections) {
        return false;
    }

    seg->nsects = nsects;

    const uint8_t *sec_base = raw + 8 + SEG_PREFIX_SIZE;

    for (uint32_t i = 0; i < nsects; i++) {
        const uint8_t *p = sec_base + i * SEC_ENTRY_SIZE;
        uint32_t       offset;

        memcpy(&offset, p + SEC_OFFSET_FIELD, 4);

        if (swap) {
            offset = macho_swap32(offset);
        }

        seg->sections[i].offset = offset;
    }

    return true;
}

// ============================================================================
// parse_single — parse one Mach-O slice starting at `slice_off`.
// ============================================================================

static n00b_result_t(macho_binary_t *)
parse_single(macho_stream_t *stream, uint64_t slice_off)
{
    n00b_buffer_t  *buf = stream->buf;
    macho_binary_t *bin = (macho_binary_t *)calloc(1, sizeof(*bin));

    if (!bin) {
        return n00b_result_err(macho_binary_t *, ENOMEM);
    }

    bin->stream     = stream;
    bin->fat_offset = slice_off;

    bool swap = false;

    if (!parse_header(buf, (size_t)slice_off, &bin->header, &swap)) {
        free(bin);
        return n00b_result_err(macho_binary_t *, MACHO_ERR_PARSE);
    }

    stream->swap_endian = swap;

    // Walk load commands.
    uint32_t ncmds      = bin->header.ncmds;
    uint32_t sizeofcmds = bin->header.sizeofcmds;
    size_t   lc_start   = (size_t)slice_off + MACHO64_HEADER_SIZE;
    size_t   lc_end     = lc_start + sizeofcmds;

    if (lc_end > buf->byte_len) {
        free(bin);
        return n00b_result_err(macho_binary_t *, MACHO_ERR_CORRUPTED);
    }

    if (ncmds > 0) {
        bin->commands = (macho_command_t *)calloc(ncmds,
                                                  sizeof(macho_command_t));

        if (!bin->commands) {
            free(bin);
            return n00b_result_err(macho_binary_t *, ENOMEM);
        }
    }

    bin->num_commands = ncmds;

    // First pass: count LC_SEGMENT_64 to size the segments array.
    uint32_t nseg = 0;
    {
        size_t pos = lc_start;

        for (uint32_t i = 0; i < ncmds; i++) {
            uint32_t cmd, cmdsize;

            if (!read_u32(buf, pos,     swap, &cmd) ||
                !read_u32(buf, pos + 4, swap, &cmdsize) ||
                cmdsize < 8 || pos + cmdsize > lc_end) {
                free(bin->commands);
                free(bin);
                return n00b_result_err(macho_binary_t *,
                                        MACHO_ERR_CORRUPTED);
            }

            if (cmd == LC_SEGMENT_64) {
                nseg++;
            }

            pos += cmdsize;
        }
    }

    if (nseg > 0) {
        bin->segments = (macho_segment_t *)calloc(nseg,
                                                  sizeof(macho_segment_t));

        if (!bin->segments) {
            free(bin->commands);
            free(bin);
            return n00b_result_err(macho_binary_t *, ENOMEM);
        }
    }

    // Second pass: fill commands[] and segments[].
    {
        size_t pos = lc_start;
        uint32_t seg_i = 0;

        for (uint32_t i = 0; i < ncmds; i++) {
            uint32_t cmd, cmdsize;
            (void)read_u32(buf, pos,     swap, &cmd);
            (void)read_u32(buf, pos + 4, swap, &cmdsize);

            bin->commands[i].cmd     = cmd;
            bin->commands[i].cmdsize = cmdsize;
            bin->commands[i].raw_data =
                n00b_buffer_from_bytes(buf->data + pos, (int64_t)cmdsize);

            if (!bin->commands[i].raw_data) {
                // Roll back what we've allocated so far.
                for (uint32_t k = 0; k < i; k++) {
                    n00b_buffer_destroy(bin->commands[k].raw_data);
                }

                free(bin->commands);

                for (uint32_t k = 0; k < seg_i; k++) {
                    free(bin->segments[k].sections);
                }

                free(bin->segments);
                free(bin);
                return n00b_result_err(macho_binary_t *, ENOMEM);
            }

            if (cmd == LC_SEGMENT_64) {
                if (!parse_segment_sections((const uint8_t *)buf->data + pos,
                                            cmdsize, swap,
                                            &bin->segments[seg_i])) {
                    // Don't fail the whole parse — leave nsects=0.
                }

                seg_i++;
            }

            pos += cmdsize;
        }

        bin->num_segments = seg_i;
    }

    return n00b_result_ok(macho_binary_t *, bin);
}

// ============================================================================
// macho_parse — handles fat or thin.
// ============================================================================

n00b_result_t(macho_fat_t *)
macho_parse(macho_stream_t *stream)
{
    if (!stream || !stream->buf) {
        return n00b_result_err(macho_fat_t *, MACHO_ERR_PARSE);
    }

    n00b_buffer_t *buf = stream->buf;

    if (buf->byte_len < 4) {
        return n00b_result_err(macho_fat_t *, MACHO_ERR_PARSE);
    }

    uint32_t magic;

    memcpy(&magic, buf->data, 4);

    macho_fat_t *fat = (macho_fat_t *)calloc(1, sizeof(*fat));

    if (!fat) {
        return n00b_result_err(macho_fat_t *, ENOMEM);
    }

    fat->stream = stream;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // Fat header: magic(4) nfat_arch(4) then nfat_arch x
        // fat_arch{cputype(4) cpusubtype(4) offset(4) size(4) align(4)}.
        // Always BIG-endian on disk regardless of host.  Swap when
        // the host's natural read disagrees with the on-disk magic.
        //
        //   magic-as-read == FAT_MAGIC  iff host is BE  → no swap.
        //   magic-as-read == FAT_CIGAM  iff host is LE  → must swap.
        bool host_le  = host_is_little_endian();
        bool fat_swap = (magic == FAT_MAGIC) ? !host_le : host_le;

        uint32_t nfat;

        if (!read_u32(buf, 4, fat_swap, &nfat) || nfat == 0
            || (uint64_t)8 + (uint64_t)nfat * 20 > buf->byte_len) {
            free(fat);
            return n00b_result_err(macho_fat_t *, MACHO_ERR_PARSE);
        }

        fat->binaries = (macho_binary_t **)calloc(nfat,
                                                  sizeof(macho_binary_t *));

        if (!fat->binaries) {
            free(fat);
            return n00b_result_err(macho_fat_t *, ENOMEM);
        }

        for (uint32_t i = 0; i < nfat; i++) {
            uint32_t slice_off;

            if (!read_u32(buf, 8 + 20u * i + 8, fat_swap, &slice_off)) {
                chalk_macho_free(fat);
                return n00b_result_err(macho_fat_t *, MACHO_ERR_CORRUPTED);
            }

            n00b_result_t(macho_binary_t *) br = parse_single(stream,
                                                              slice_off);

            if (n00b_result_is_err(br)) {
                chalk_macho_free(fat);
                return n00b_result_err(macho_fat_t *,
                                        n00b_result_get_err(br));
            }

            fat->binaries[i]          = (macho_binary_t *)n00b_result_get(br);
            fat->binaries[i]->is_fat  = true;
            fat->count                = i + 1;
        }

        return n00b_result_ok(macho_fat_t *, fat);
    }

    // Thin Mach-O.
    n00b_result_t(macho_binary_t *) br = parse_single(stream, 0);

    if (n00b_result_is_err(br)) {
        free(fat);
        return n00b_result_err(macho_fat_t *, n00b_result_get_err(br));
    }

    fat->binaries    = (macho_binary_t **)calloc(1, sizeof(macho_binary_t *));

    if (!fat->binaries) {
        macho_binary_t *bin = (macho_binary_t *)n00b_result_get(br);
        // Hand-free since we don't yet have the fat to walk.
        for (uint32_t k = 0; k < bin->num_commands; k++) {
            n00b_buffer_destroy(bin->commands[k].raw_data);
        }

        free(bin->commands);

        for (uint32_t k = 0; k < bin->num_segments; k++) {
            free(bin->segments[k].sections);
        }

        free(bin->segments);
        free(bin);
        free(fat);
        return n00b_result_err(macho_fat_t *, ENOMEM);
    }

    fat->binaries[0] = (macho_binary_t *)n00b_result_get(br);
    fat->count       = 1;
    return n00b_result_ok(macho_fat_t *, fat);
}

// ============================================================================
// chalk_macho_free — walk and free everything macho_parse allocated.
// ============================================================================

void
chalk_macho_free(macho_fat_t *fat)
{
    if (!fat) {
        return;
    }

    if (fat->binaries) {
        for (uint32_t i = 0; i < fat->count; i++) {
            macho_binary_t *bin = fat->binaries[i];

            if (!bin) {
                continue;
            }

            if (bin->commands) {
                for (uint32_t k = 0; k < bin->num_commands; k++) {
                    n00b_buffer_destroy(bin->commands[k].raw_data);
                }

                free(bin->commands);
            }

            if (bin->segments) {
                for (uint32_t k = 0; k < bin->num_segments; k++) {
                    free(bin->segments[k].sections);
                }

                free(bin->segments);
            }

            free(bin);
        }

        free(fat->binaries);
    }

    macho_stream_free(fat->stream);
    free(fat);
}
