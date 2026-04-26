/**
 * @file chalk_macho.h
 * @brief Chalk's LC_NOTE-focused public API on top of the carved
 *        Mach-O parser.
 *
 * The chalk codec marks Mach-O binaries by inserting an `LC_NOTE`
 * load command whose `data_owner` field identifies it as chalk's,
 * with the chalk-mark JSON payload appended at end-of-file.  This
 * mirrors the approach the existing nim ELF codec takes: parse to
 * find offsets, splice the file's raw bytes in place, patch a few
 * header integer fields, then reparse.  The carved Mach-O builder
 * (`macho_build.c`) was dropped — chalk does not rebuild from parsed
 * structs.
 *
 * On-disk layout (from Apple's <mach-o/loader.h>):
 *
 *     struct note_command {
 *         uint32_t cmd;             // LC_NOTE (0x31)
 *         uint32_t cmdsize;         // 40
 *         char     data_owner[16];  // owner name, NUL-padded
 *         uint64_t offset;          // file offset of payload
 *         uint64_t size;            // payload length in bytes
 *     };
 */
#pragma once

#include "macho.h"

// ============================================================================
// On-disk note_command struct (40 bytes, NOT in macho_types.h yet).
// ============================================================================

#pragma pack(push, 1)
typedef struct {
    uint32_t cmd;
    uint32_t cmdsize;
    char     data_owner[16];
    uint64_t offset;
    uint64_t size;
} macho_note_command_t;
#pragma pack(pop)

// ============================================================================
// Read API — works against any parsed binary.
// ============================================================================

/// Owner string used for chalk's marks.  Apple's data_owner field is
/// fixed at 16 bytes, padded with NULs.  "chalk" + 11 NUL bytes.
#define CHALK_MACHO_NOTE_OWNER  "chalk"

// ============================================================================
// Diagnostics
//
// `chalk_macho_warn(const char *msg)` is the diagnostic sink the C
// code calls.  It is declared `extern` inside chalk_macho.c (not in
// this public header — declaring it here clashed with nim's
// hidden-visibility codegen when nim provides the strong override).
// The C side's default is a weak fprintf-to-stderr; nim's
// `proc chalk_macho_warn(msg: cstring) {.cdecl, exportc.}` overrides
// it at link time when chalk's main binary is built.
// ============================================================================

typedef struct {
    char     data_owner[17]; ///< NUL-terminated copy of the 16-byte owner.
    uint64_t payload_offset; ///< File offset of the note payload.
    uint64_t payload_size;   ///< Length of the payload in bytes.
    uint8_t *payload;        ///< Pointer into bin->stream's backing
                             ///< buffer for the payload bytes; NULL if
                             ///< the offset/size point outside the file.
                             ///< Caller MUST NOT free.  Lifetime is tied
                             ///< to the parsed binary's stream buffer.
} chalk_macho_note_t;

/**
 * @brief Enumerate all LC_NOTE entries in a parsed binary.
 *
 * @param bin       Parsed Mach-O binary.
 * @param out_count Receives the number of notes returned.
 * @return Array of @p *out_count notes (caller frees the array via
 *         free(); do not free .payload).  NULL if @p bin has no
 *         LC_NOTE commands or on allocation failure.
 */
extern chalk_macho_note_t *chalk_macho_get_notes(macho_binary_t *bin,
                                                  size_t *out_count);

/// Code-signature classification for `chalk_macho_signature_kind`.
typedef enum {
    CHALK_MACHO_SIG_NONE      = 0, ///< no LC_CODE_SIGNATURE
    CHALK_MACHO_SIG_ADHOC     = 1, ///< CodeDirectory present, CMS empty
    CHALK_MACHO_SIG_REAL_CERT = 2, ///< CMS / Developer ID signature
    CHALK_MACHO_SIG_MALFORMED = 3, ///< LC present but blob unreadable
} chalk_macho_sig_kind_t;

/**
 * @brief Classify the binary's code signature.
 *
 * chalk uses this to gate in-place mutation:
 *   - SIG_NONE  → mutate freely.
 *   - SIG_ADHOC → mutate, then re-sign with `codesign -s -`.
 *   - SIG_REAL_CERT → refuse, defer to wrapper codec (we don't have
 *                     the cert / private key to re-sign).
 *   - SIG_MALFORMED → refuse, defer.
 *
 * Reads from bin->stream->buf, no allocation.
 */
extern chalk_macho_sig_kind_t chalk_macho_signature_kind(macho_binary_t *bin);

/**
 * @brief Find the chalk LC_NOTE and copy its payload into a freshly-
 *        allocated buffer.
 *
 * @param bin      Parsed Mach-O binary.
 * @param out_size Receives the payload size in bytes.
 * @return malloc'd payload bytes (caller frees), or NULL if no chalk
 *         note is present.
 */
extern uint8_t *chalk_macho_get_chalk_payload(macho_binary_t *bin,
                                              size_t *out_size);

// ============================================================================
// Status codes
// ============================================================================

typedef enum {
    CHALK_MACHO_OK                     =  0,
    CHALK_MACHO_ERR_NULL_BINARY        = -1,
    CHALK_MACHO_ERR_TOO_LARGE          = -2, ///< new sizeofcmds > UINT32_MAX
    CHALK_MACHO_ERR_NO_LC_SLACK        = -3, ///< not enough room between
                                             ///< LC region end and first
                                             ///< section's file offset to
                                             ///< grow the LC table by 40 B
    CHALK_MACHO_ERR_NO_CHALK_NOTE      = -4, ///< remove_note: nothing to do
    CHALK_MACHO_ERR_FAT                = -5, ///< not implemented for fat
    CHALK_MACHO_ERR_BAD_NOTE           = -6, ///< malformed note_command in
                                             ///< binary (cmdsize wrong etc.)
    CHALK_MACHO_ERR_INTERNAL           = -7,
} chalk_macho_status_t;

// ============================================================================
// In-place mutation API
//
// These functions mutate the raw bytes inside the binary's stream
// buffer.  After a successful call, callers MUST treat the parsed
// `macho_binary_t *bin` as stale: the load command pointers,
// segment/section offsets, etc. all refer to pre-mutation data.
// Reparse the stream (or call chalk_macho_get_buffer() to retrieve
// the new bytes and write them out) before further use.
// ============================================================================

/**
 * @brief Insert or replace the chalk LC_NOTE in a parsed binary.
 *
 * If a chalk LC_NOTE is already present (data_owner == "chalk"), its
 * payload is replaced in place — the load command stays put, only
 * the on-disk note_command's `offset`/`size` are repointed at the
 * fresh payload appended at EOF.  The old payload bytes are NOT
 * reclaimed (file may grow slightly across re-marks); chalk's mark
 * payload is small enough that this is fine in practice.
 *
 * If no chalk LC_NOTE is present, one is appended to the load
 * command table and the payload is appended at EOF.
 *
 * @param bin            Parsed binary.  Must be a thin (non-fat)
 *                       Mach-O 64.  Refused otherwise.
 * @param payload        Mark payload bytes.
 * @param payload_size   Payload length.
 * @return CHALK_MACHO_OK on success, or CHALK_MACHO_ERR_*.
 *
 * @post On success, the bin->stream buffer holds the mutated bytes.
 *       The parsed structs (bin->commands[], bin->segments[], etc.)
 *       are STALE — caller must reparse if more inspection is needed.
 */
/**
 * @brief Strip the existing code signature (if any) in place.
 *
 * Removes the LC_CODE_SIGNATURE load command, shifts later commands
 * up within the LC region, zero-pads the trailing 16 bytes (slack),
 * truncates the file at the old signature's dataoff (dropping the
 * old signature blob), shrinks __LINKEDIT.filesize accordingly,
 * patches mh_header.ncmds and sizeofcmds.
 *
 * After stripping, the binary has no signature; chalk_macho_add_note
 * can then place its payload at the end of __LINKEDIT, and a
 * subsequent `codesign --force --sign -` adds a fresh signature blob
 * past our payload — all inside __LINKEDIT.  Apple's codesign
 * silently corrupts our payload if any of these steps are skipped.
 *
 * No-op if no signature is present.
 *
 * @return CHALK_MACHO_OK on success.
 *         CHALK_MACHO_ERR_FAT for fat binaries.
 *         CHALK_MACHO_ERR_BAD_NOTE if structure is malformed.
 */
extern chalk_macho_status_t chalk_macho_strip_signature(macho_binary_t *bin);

extern chalk_macho_status_t chalk_macho_add_note(macho_binary_t *bin,
                                                  const uint8_t *payload,
                                                  size_t payload_size);

/**
 * @brief Remove the chalk LC_NOTE from a parsed binary.
 *
 * The 40-byte note_command is spliced out of the LC region (later
 * commands shift up by 40 bytes).  The payload bytes at EOF are
 * NOT reclaimed (they become trailing junk; chalk_macho's
 * unchalk-then-rechalk pattern will naturally reuse the slot or
 * append fresh).
 *
 * For a clean removal that also reclaims the payload bytes, callers
 * who hold the only LC_NOTE should follow with truncating the file
 * to the parsed binary's data extent.  PR 2 doesn't offer that helper.
 *
 * @param bin Parsed binary.
 * @return CHALK_MACHO_OK on success.
 *         CHALK_MACHO_ERR_NO_CHALK_NOTE if absent.
 *         CHALK_MACHO_ERR_* on failure.
 *
 * @post On success, bin's parsed structs are STALE.
 */
extern chalk_macho_status_t chalk_macho_remove_note(macho_binary_t *bin);

/**
 * @brief Compute the chalk "unchalked hash" of a binary.
 *
 * Mirrors `elf.nim`'s getUnchalkedHash semantics: the SHA-256 of the
 * binary as if its chalk payload were replaced with `payload_size`
 * zero bytes.  The hash is invariant under remarking with payloads
 * of the same length.
 *
 * If no chalk LC_NOTE is present, returns the SHA-256 of the bytes
 * as-is.
 *
 * @param bin       Parsed binary.
 * @param out_hex   Caller-provided buffer of at least 65 bytes
 *                  (64 hex chars + NUL).  Receives the lowercase
 *                  hex digest on success.
 * @return CHALK_MACHO_OK on success, or CHALK_MACHO_ERR_*.
 */
extern chalk_macho_status_t chalk_macho_unchalked_hash(macho_binary_t *bin,
                                                       char out_hex[65]);

/**
 * @brief Retrieve the (possibly mutated) raw bytes of a binary.
 *
 * After chalk_macho_add_note / remove_note, callers use this to
 * obtain the new file contents to write back to disk.
 *
 * @param bin       Parsed binary.
 * @param out_size  Receives the byte length.
 * @return Pointer into bin->stream's backing buffer (NOT owned;
 *         lifetime tied to the parsed binary).  NULL on error.
 */
extern const uint8_t *chalk_macho_get_buffer(macho_binary_t *bin,
                                             size_t *out_size);
