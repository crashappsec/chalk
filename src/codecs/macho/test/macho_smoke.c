/**
 * @file macho_smoke.c
 * @brief Smoke test for the carved Mach-O codec.
 *
 * Three modes:
 *   info <path>            — parse + dump header / load commands / notes.
 *   roundtrip <path> <out> — parse, add chalk note, write to <out>,
 *                            reparse <out>, remove note, write back,
 *                            verify state at each step.
 *   hash <path>            — print the unchalked hash.
 *
 * Used to validate the carve in isolation before nim/chalk integration.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <errno.h>

#include "macho.h"
#include "macho_stream.h"
#include "macho_types.h"
#include "chalk_macho.h"

// ============================================================================
// Helpers
// ============================================================================

static const char *
filetype_name(uint32_t t)
{
    switch (t) {
    case MH_OBJECT:      return "OBJECT";
    case MH_EXECUTE:     return "EXECUTE";
    case MH_DYLIB:       return "DYLIB";
    case MH_DYLINKER:    return "DYLINKER";
    case MH_BUNDLE:      return "BUNDLE";
    case MH_DSYM:        return "DSYM";
    case MH_KEXT_BUNDLE: return "KEXT_BUNDLE";
    case MH_FILESET:     return "FILESET";
    default:             return "?";
    }
}

static const char *
cputype_name(uint32_t t)
{
    switch (t) {
    case CPU_TYPE_X86:    return "x86";
    case CPU_TYPE_X86_64: return "x86_64";
    case CPU_TYPE_ARM:    return "arm";
    case CPU_TYPE_ARM64:  return "arm64";
    default:              return "?";
    }
}

static const char *
lc_name(uint32_t cmd)
{
    switch (cmd) {
    case LC_SEGMENT_64:           return "LC_SEGMENT_64";
    case LC_SYMTAB:               return "LC_SYMTAB";
    case LC_DYSYMTAB:             return "LC_DYSYMTAB";
    case LC_LOAD_DYLIB:           return "LC_LOAD_DYLIB";
    case LC_LOAD_WEAK_DYLIB:      return "LC_LOAD_WEAK_DYLIB";
    case LC_REEXPORT_DYLIB:       return "LC_REEXPORT_DYLIB";
    case LC_ID_DYLIB:             return "LC_ID_DYLIB";
    case LC_LOAD_DYLINKER:        return "LC_LOAD_DYLINKER";
    case LC_UUID:                 return "LC_UUID";
    case LC_MAIN:                 return "LC_MAIN";
    case LC_DYLD_INFO_ONLY:       return "LC_DYLD_INFO_ONLY";
    case LC_FUNCTION_STARTS:      return "LC_FUNCTION_STARTS";
    case LC_CODE_SIGNATURE:       return "LC_CODE_SIGNATURE";
    case LC_SOURCE_VERSION:       return "LC_SOURCE_VERSION";
    case LC_BUILD_VERSION:        return "LC_BUILD_VERSION";
    case LC_VERSION_MIN_MACOSX:   return "LC_VERSION_MIN_MACOSX";
    case LC_RPATH:                return "LC_RPATH";
    case LC_DATA_IN_CODE:         return "LC_DATA_IN_CODE";
    case LC_ENCRYPTION_INFO_64:   return "LC_ENCRYPTION_INFO_64";
    case LC_DYLD_CHAINED_FIXUPS:  return "LC_DYLD_CHAINED_FIXUPS";
    case LC_DYLD_EXPORTS_TRIE:    return "LC_DYLD_EXPORTS_TRIE";
    case LC_NOTE:                 return "LC_NOTE";
    case LC_LINKER_OPTION:        return "LC_LINKER_OPTION";
    default:                      return "?";
    }
}

static macho_fat_t *
parse_path(const char *path)
{
    n00b_result_carrier_t sr = macho_stream_from_file(path);

    if (n00b_result_is_err(sr)) {
        fprintf(stderr, "%s: failed to read (err=%d)\n",
                path, n00b_result_get_err(sr));
        return NULL;
    }

    macho_stream_t *stream = (macho_stream_t *)n00b_result_get(sr);

    n00b_result_carrier_t fr = macho_parse(stream);

    if (n00b_result_is_err(fr)) {
        fprintf(stderr, "%s: parse failed (err=%d)\n",
                path, n00b_result_get_err(fr));
        return NULL;
    }

    return (macho_fat_t *)n00b_result_get(fr);
}

static void
dump_binary(macho_binary_t *bin)
{
    printf("  cputype=%s filetype=%s ncmds=%u sizeofcmds=%u\n",
           cputype_name(bin->header.cputype),
           filetype_name(bin->header.filetype),
           bin->header.ncmds,
           bin->header.sizeofcmds);
    printf("  %u segments\n", bin->num_segments);

    printf("  load commands:\n");

    for (uint32_t i = 0; i < bin->num_commands; i++) {
        printf("    [%2u] %-26s cmdsize=%u\n",
               i,
               lc_name(bin->commands[i].cmd),
               bin->commands[i].cmdsize);
    }

    size_t              note_count = 0;
    chalk_macho_note_t *notes      = chalk_macho_get_notes(bin, &note_count);

    printf("  LC_NOTE entries: %zu\n", note_count);

    for (size_t i = 0; i < note_count; i++) {
        printf("    data_owner=\"%s\" offset=%" PRIu64 " size=%" PRIu64
               "%s\n",
               notes[i].data_owner,
               notes[i].payload_offset,
               notes[i].payload_size,
               notes[i].payload ? "" : " (payload OUT OF FILE)");
    }

    free(notes);
}

static int
write_buffer(const char *path, const uint8_t *bytes, size_t len)
{
    FILE *f = fopen(path, "wb");

    if (!f) {
        fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
        return 1;
    }

    size_t n = fwrite(bytes, 1, len, f);
    fclose(f);

    if (n != len) {
        fprintf(stderr, "%s: short write (%zu of %zu)\n", path, n, len);
        return 1;
    }

    return 0;
}

// ============================================================================
// Modes
// ============================================================================

static int
mode_info(const char *path)
{
    macho_fat_t *fat = parse_path(path);

    if (!fat) {
        return 1;
    }

    printf("file:   %s\n", path);
    printf("slices: %u\n", fat->count);

    for (uint32_t s = 0; s < fat->count; s++) {
        printf("  [slice %u]\n", s);

        if (fat->binaries[s]) {
            dump_binary(fat->binaries[s]);
        }
    }

    chalk_macho_free(fat);
    return 0;
}

static int
mode_mark(const char *path, const char *out_path)
{
    static const uint8_t kPayload[] = "{\"chalk\":\"smoke\"}";
    const size_t kLen = sizeof(kPayload) - 1;

    macho_fat_t *fat = parse_path(path);
    if (!fat || !fat->binaries[0]) {
        chalk_macho_free(fat);
        return 1;
    }

    // Strip any existing signature first — chalk_macho_add_note
    // requires no LC_CODE_SIGNATURE present so the payload can land
    // at the end of __LINKEDIT.  A subsequent codesign --force --sign -
    // adds a fresh signature past our payload.
    chalk_macho_status_t st = chalk_macho_strip_signature(fat->binaries[0]);
    if (st != CHALK_MACHO_OK) {
        fprintf(stderr, "strip_signature failed: %d\n", st);
        chalk_macho_free(fat);
        return 1;
    }

    st = chalk_macho_add_note(fat->binaries[0], kPayload, kLen);
    if (st != CHALK_MACHO_OK) {
        fprintf(stderr, "add_note failed: %d\n", st);
        chalk_macho_free(fat);
        return 1;
    }

    size_t         out_len = 0;
    const uint8_t *bytes   = chalk_macho_get_buffer(fat->binaries[0],
                                                     &out_len);

    int rc = write_buffer(out_path, bytes, out_len);
    chalk_macho_free(fat);
    return rc;
}

static int
mode_sig(const char *path)
{
    macho_fat_t *fat = parse_path(path);

    if (!fat || fat->count == 0 || !fat->binaries[0]) {
        chalk_macho_free(fat);
        return 1;
    }

    chalk_macho_sig_kind_t kind = chalk_macho_signature_kind(fat->binaries[0]);

    static const char *names[] = {
        [CHALK_MACHO_SIG_NONE]      = "none",
        [CHALK_MACHO_SIG_ADHOC]     = "adhoc",
        [CHALK_MACHO_SIG_REAL_CERT] = "real_cert",
        [CHALK_MACHO_SIG_MALFORMED] = "malformed",
    };

    printf("%-10s  %s\n", names[kind], path);
    chalk_macho_free(fat);
    return 0;
}

static int
mode_hash(const char *path)
{
    macho_fat_t *fat = parse_path(path);

    if (!fat || fat->count == 0 || !fat->binaries[0]) {
        chalk_macho_free(fat);
        return 1;
    }

    char hex[65];
    int  rc = 0;

    if (chalk_macho_unchalked_hash(fat->binaries[0], hex) != CHALK_MACHO_OK) {
        fprintf(stderr, "%s: hash failed\n", path);
        rc = 1;
    }
    else {
        printf("%s  %s\n", hex, path);
    }

    chalk_macho_free(fat);
    return rc;
}

static int
mode_roundtrip(const char *path, const char *out_path)
{
    static const uint8_t kTestPayload[] =
        "{\"chalk\": \"test mark\", \"id\": \"abc123\"}";
    const size_t kTestPayloadLen = sizeof(kTestPayload) - 1;

    // ----- 1. Parse, baseline hash, add note -----
    macho_fat_t *fat = parse_path(path);

    if (!fat || fat->count == 0 || !fat->binaries[0]) {
        return 1;
    }

    macho_binary_t *bin = fat->binaries[0];

    char baseline_hex[65];

    if (chalk_macho_unchalked_hash(bin, baseline_hex) != CHALK_MACHO_OK) {
        fprintf(stderr, "baseline hash failed\n");
        return 1;
    }

    printf("baseline:\n");
    printf("  unchalked hash: %s\n", baseline_hex);

    chalk_macho_status_t st = chalk_macho_strip_signature(bin);

    if (st != CHALK_MACHO_OK) {
        fprintf(stderr, "strip_signature failed: %d\n", st);
        return 1;
    }

    st = chalk_macho_add_note(bin,
                                                    kTestPayload,
                                                    kTestPayloadLen);

    if (st != CHALK_MACHO_OK) {
        fprintf(stderr, "add_note failed: %d\n", st);
        return 1;
    }

    size_t         out_len   = 0;
    const uint8_t *out_bytes = chalk_macho_get_buffer(bin, &out_len);

    if (!out_bytes) {
        fprintf(stderr, "get_buffer returned NULL after add\n");
        return 1;
    }

    if (write_buffer(out_path, out_bytes, out_len) != 0) {
        return 1;
    }

    printf("after add_note: wrote %zu bytes to %s\n", out_len, out_path);

    // ----- 2. Reparse the marked file and check the chalk payload -----
    macho_fat_t    *fat2 = parse_path(out_path);
    macho_binary_t *bin2 = fat2 ? fat2->binaries[0] : NULL;

    if (!bin2) {
        fprintf(stderr, "reparse of %s failed\n", out_path);
        return 1;
    }

    printf("reparsed marked file:\n");
    dump_binary(bin2);

    size_t   chalk_size    = 0;
    uint8_t *chalk_payload = chalk_macho_get_chalk_payload(bin2, &chalk_size);

    if (!chalk_payload) {
        fprintf(stderr, "no chalk payload found after add\n");
        return 1;
    }

    if (chalk_size != kTestPayloadLen
        || memcmp(chalk_payload, kTestPayload, kTestPayloadLen) != 0) {
        fprintf(stderr, "chalk payload mismatch after add\n");
        free(chalk_payload);
        return 1;
    }

    free(chalk_payload);
    printf("  chalk payload matches injected bytes\n");

    char marked_hex[65];

    if (chalk_macho_unchalked_hash(bin2, marked_hex) != CHALK_MACHO_OK) {
        fprintf(stderr, "marked hash failed\n");
        return 1;
    }

    printf("  unchalked hash: %s%s\n", marked_hex,
           strcmp(marked_hex, baseline_hex) == 0
             ? "  (== baseline ✓)"
             : "  (!= baseline ✗)");

    // ----- 3. Remove the note, write back, reparse, confirm gone -----
    st = chalk_macho_remove_note(bin2);

    if (st != CHALK_MACHO_OK) {
        fprintf(stderr, "remove_note failed: %d\n", st);
        return 1;
    }

    out_bytes = chalk_macho_get_buffer(bin2, &out_len);

    if (write_buffer(out_path, out_bytes, out_len) != 0) {
        return 1;
    }

    printf("after remove_note: wrote %zu bytes to %s\n", out_len, out_path);

    macho_fat_t    *fat3 = parse_path(out_path);
    macho_binary_t *bin3 = fat3 ? fat3->binaries[0] : NULL;

    if (!bin3) {
        fprintf(stderr, "reparse after remove failed\n");
        return 1;
    }

    chalk_payload = chalk_macho_get_chalk_payload(bin3, &chalk_size);

    if (chalk_payload) {
        fprintf(stderr, "chalk payload still present after remove\n");
        free(chalk_payload);
        chalk_macho_free(fat);
        chalk_macho_free(fat2);
        chalk_macho_free(fat3);
        return 1;
    }

    printf("after remove: no chalk note found ✓\n");

    chalk_macho_free(fat);
    chalk_macho_free(fat2);
    chalk_macho_free(fat3);
    return 0;
}

// ============================================================================
// main
// ============================================================================

int
main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
                "usage:\n"
                "  %s info <path>\n"
                "  %s roundtrip <in-path> <out-path>\n"
                "  %s hash <path>\n"
                "\n"
                "(legacy)  %s <path>     — same as `info`.\n",
                argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }

    if (argc == 2) {
        // Legacy single-arg form for compatibility.
        return mode_info(argv[1]);
    }

    const char *cmd = argv[1];

    if (strcmp(cmd, "info") == 0 && argc == 3) {
        return mode_info(argv[2]);
    }

    if (strcmp(cmd, "hash") == 0 && argc == 3) {
        return mode_hash(argv[2]);
    }

    if (strcmp(cmd, "sig") == 0 && argc == 3) {
        return mode_sig(argv[2]);
    }

    if (strcmp(cmd, "mark") == 0 && argc == 4) {
        return mode_mark(argv[2], argv[3]);
    }

    if (strcmp(cmd, "roundtrip") == 0 && argc == 4) {
        return mode_roundtrip(argv[2], argv[3]);
    }

    fprintf(stderr, "bad arguments\n");
    return 2;
}
