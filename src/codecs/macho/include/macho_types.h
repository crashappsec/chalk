/**
 * @file macho_types.h
 * @brief Mach-O on-disk constants — magic numbers, file types, CPU
 *        types, and load command tags.
 *
 * Trimmed to just the constants chalk uses (smoke test + slim
 * parser).  Opcode constants for binding/rebase/export tries were
 * dropped — chalk doesn't decode dyld-info.
 */
#pragma once

#include <stdint.h>

// ============================================================================
// Mach-O magic numbers
// ============================================================================

#define MH_MAGIC_64    0xFEEDFACFu
#define MH_CIGAM_64    0xCFFAEDFEu
#define FAT_MAGIC      0xCAFEBABEu
#define FAT_CIGAM      0xBEBAFECAu

// ============================================================================
// File types
// ============================================================================

#define MH_OBJECT       1
#define MH_EXECUTE      2
#define MH_DYLIB        6
#define MH_DYLINKER     7
#define MH_BUNDLE       8
#define MH_DSYM         10
#define MH_KEXT_BUNDLE  11
#define MH_FILESET      12

// ============================================================================
// CPU types
// ============================================================================

#define CPU_TYPE_X86       7
#define CPU_TYPE_X86_64    (CPU_TYPE_X86 | 0x01000000)
#define CPU_TYPE_ARM       12
#define CPU_TYPE_ARM64     (CPU_TYPE_ARM | 0x01000000)

// ============================================================================
// Load command tags (subset — what chalk references)
// ============================================================================

#define LC_REQ_DYLD                0x80000000u

#define LC_SEGMENT_64              0x19
#define LC_SYMTAB                  0x02
#define LC_DYSYMTAB                0x0B
#define LC_LOAD_DYLIB              0x0C
#define LC_ID_DYLIB                0x0D
#define LC_LOAD_DYLINKER           0x0E
#define LC_LOAD_WEAK_DYLIB         (0x18 | LC_REQ_DYLD)
#define LC_REEXPORT_DYLIB          (0x1F | LC_REQ_DYLD)
#define LC_UUID                    0x1B
#define LC_RPATH                   (0x1C | LC_REQ_DYLD)
#define LC_CODE_SIGNATURE          0x1D
#define LC_DYLD_INFO_ONLY          (0x22 | LC_REQ_DYLD)
#define LC_VERSION_MIN_MACOSX      0x24
#define LC_FUNCTION_STARTS         0x26
#define LC_MAIN                    (0x28 | LC_REQ_DYLD)
#define LC_DATA_IN_CODE            0x29
#define LC_SOURCE_VERSION          0x2A
#define LC_ENCRYPTION_INFO_64      0x2C
#define LC_LINKER_OPTION           0x2D
#define LC_NOTE                    0x31
#define LC_BUILD_VERSION           0x32
#define LC_DYLD_EXPORTS_TRIE       (0x33 | LC_REQ_DYLD)
#define LC_DYLD_CHAINED_FIXUPS     (0x34 | LC_REQ_DYLD)

// ============================================================================
// On-disk header layout (mach_header_64 = 32 bytes)
// ============================================================================

#define MACHO64_HEADER_SIZE        32
