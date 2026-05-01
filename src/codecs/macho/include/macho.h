/**
 * @file macho.h
 * @brief Slim Mach-O parser tuned for chalk's needs.
 *
 * History: this started as a carve of an in-house lief-c parser
 * (~5500 LOC) which produced fully-parsed binaries with symbols,
 * dylibs, bindings, rebases, exports, code-signature deep parse,
 * dyld chained fixups, build versions, and so on.  Chalk doesn't
 * use any of that — it only needs:
 *
 *   - the mach_header_64 fields (magic / cputype / filetype / ncmds /
 *     sizeofcmds), to drive header patches;
 *   - the load command table (cmd / cmdsize / raw bytes), to find
 *     LC_NOTE entries and walk command offsets;
 *   - the smallest section file offset across LC_SEGMENT_64 commands,
 *     to compute load-command slack for in-place insertion;
 *   - the raw bytes of the binary, for splicing.
 *
 * So this file declares only those structures; macho.c implements a
 * focused parser; macho_query.c was dropped.  See chalk_macho.h for
 * the LC_NOTE-focused public API on top.
 */
#pragma once

#include "n00b_shim.h"
#include "macho_common.h"
#include "macho_stream.h"
#include "macho_types.h"

// ============================================================================
// Parsed header (mach_header_64 fields, host endian after parse).
// ============================================================================

typedef struct macho_header {
    uint32_t magic;
    uint32_t cputype;
    uint32_t cpusubtype;
    uint32_t filetype;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    uint32_t flags;
    uint32_t reserved;
} macho_header_t;

// ============================================================================
// Load command — tag + raw bytes.
//
// raw_data holds the FULL cmdsize bytes of the command (including
// the 8-byte cmd/cmdsize header).  Owned by the parsed binary;
// freed by chalk_macho_free.
// ============================================================================

typedef struct macho_command {
    uint32_t       cmd;
    uint32_t       cmdsize;
    n00b_buffer_t *raw_data;
} macho_command_t;

// ============================================================================
// Section — only the file offset is recorded.  Chalk uses this to
// compute load-command slack (smallest section.offset > 0 must be
// >= header_end + sizeofcmds + 40 for an LC_NOTE insert to fit).
// ============================================================================

typedef struct macho_section {
    uint32_t offset;
} macho_section_t;

// ============================================================================
// Segment — section count + array of section offsets.
// ============================================================================

typedef struct macho_segment {
    uint32_t          nsects;
    macho_section_t  *sections;
} macho_segment_t;

// ============================================================================
// Top-level Mach-O binary (one slice).
// ============================================================================

typedef struct macho_binary {
    macho_header_t    header;
    macho_command_t  *commands;
    uint32_t          num_commands;
    macho_segment_t  *segments;
    uint32_t          num_segments;
    macho_stream_t   *stream;       ///< Borrowed from the owning fat.
    bool              is_fat;
    uint64_t          fat_offset;
} macho_binary_t;

// ============================================================================
// Fat container — one entry for thin Mach-O, multiple for FAT_MAGIC.
// Owns the underlying stream (and thus buffer + bytes).
// ============================================================================

typedef struct macho_fat {
    macho_binary_t **binaries;
    uint32_t         count;
    macho_stream_t  *stream;        ///< OWNED by the fat container.
} macho_fat_t;

// ============================================================================
// Parse API
// ============================================================================

/// Parse a Mach-O binary (thin or fat) from a stream.  The fat
/// container takes ownership of the stream — caller must NOT free
/// the stream after this call.  Use chalk_macho_free(fat) to release
/// everything.
extern n00b_result_t(macho_fat_t *) macho_parse(macho_stream_t *stream);

/// Free a parsed binary and everything it owns: commands + raw_data,
/// segments + sections, sub-binaries, the toplevel stream + buffer +
/// underlying byte storage.  NULL-safe; idempotent (but the caller
/// must not retain any pointers into the freed memory).
extern void chalk_macho_free(macho_fat_t *fat);
