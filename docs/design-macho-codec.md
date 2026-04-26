# Design: native Mach-O codec for chalk

**Status:** draft, awaiting review
**Author:** Claude (with John Viega)
**Last updated:** 2026-04-26

## Problem

chalk on macOS today marks Mach-O binaries by wrapping them in a bash
shell-script trampoline (see `src/plugins/codecMacOs.nim`, which calls
itself "Super cheezy"). The wrapper base64-decodes the embedded Mach-O
into `/tmp/`, hash-checks it, and `exec`s it. The chalk mark sits as
trailing text after `exec`, where bash never reads it.

This works for marking but breaks for distribution:

1. The "binary" Apple sees is a bash script with an embedded base64
   blob. Apple's notary accepts the script signature, but the
   Gatekeeper UX for shipping a script-that-extracts-a-Mach-O is poor:
   first run extracts to `/tmp` and re-execs, which is suspicious to
   security tooling and slower for users.
2. The wrapper's hardened-runtime / library-validation flags are
   meaningless on a bash script. Real protections only apply to the
   extracted Mach-O, which is unsigned in `/tmp`.
3. Universal binaries, third-party Mach-Os, and any binary the user
   doesn't trust to wrap in a script can't be marked at all.

We want chalk to mark Mach-Os *natively* — modify the binary in place
so that the result is still a Mach-O, codesign covers the mark, and
distribution looks like distribution of a normal Mac binary.

## Approach: `LC_NOTE` load command

Apple defines `LC_NOTE` (0x31) as a load command for tool-specific
metadata. It carries a 16-byte `data_owner` namespace tag and a
file-offset/size pair pointing at the metadata blob. It is:

- Ignored by `dyld` (does not affect execution).
- Preserved by `codesign`, **and** included in the signature hash, so
  tampering invalidates the signature.
- Preserved by `strip`.
- The Apple-blessed mechanism for exactly this use case.

We will write the chalk mark JSON into an `LC_NOTE` blob with
`data_owner = "crashoverride.chalk\0…"` (16 bytes, zero-padded). Format
of the JSON inside is unchanged from what the script wrapper writes
today — existing `chalk extract` consumers keep working.

### Why not other locations

| Location | Why not |
|---|---|
| Trailing data past `__LINKEDIT` | Not covered by codesign; notary may reject as "trailing junk." |
| Custom `__CHALK` segment | Strictly more invasive than LC_NOTE; segment table changes affect every offset. |
| Existing `__TEXT,__chalkmark` section | `__TEXT` is read-only and signed; modifying it breaks every previous build's reproducibility. |

LC_NOTE is the right choice.

## Implementation: vendor a Mach-O subset, FFI from nim

There is an in-house mature C23 Mach-O parser/builder at
`~/vibe/lief/` (`lief-c`, ~6000 lines). It is unreleased and lives
only on the author's machine. Rather than wrap it as an external
library, we **carve out the Mach-O-specific subset and vendor the
source into this repo** under `src/codecs/macho/`. This:

- Removes external library dependencies entirely.
- Lets us add LC_NOTE-specific helpers in-tree.
- Conditionally compiles only on macOS (no Linux/Docker risk).
- Keeps chalk self-contained: clone the repo, build, done.

Plan (working: simple-first, decide-before-PR):

1. **Bring over the Mach-O subset of lief-c into `src/codecs/macho/`,
   plus the minimum n00b subset it transitively needs.** Targeted:
   header parse, load command iteration, segment/section structures,
   build/serialize. Skip: PE, ELF, DWARF, symbol demangling,
   binding/rebase/export parsing (chalk doesn't need these). Keep
   n00b dependencies as-is for now — easier to verify the port
   works end-to-end with the original API. Estimated ~1500–2500
   lines of C from the original ~6000, plus whatever n00b transitive
   carve is required.
2. **Decide before PR whether to strip n00b.** lief-c uses n00b's
   `n00b_buffer_t`, `n00b_string_t`, `n00b_result_t`, `n00b_alloc`.
   *Optional follow-up:* rewrite the API surface to plain C types
   (`uint8_t*`/`size_t`/return codes), keep parser/builder logic
   intact. Skipped if n00b carve is small or vendoring it doesn't
   meaningfully bloat chalk; revisited if either turns out to be
   painful.
3. **Add LC_NOTE-specific helpers in the carved code:**
   - `chalk_macho_get_notes(bin) → array of {data_owner, payload}`
   - `chalk_macho_add_note(bin, data_owner, payload, len)`
   - `chalk_macho_remove_note(bin, data_owner)`
4. **meson sub-build** under `src/codecs/macho/meson.build` produces
   `libchalk_macho.a`, conditionally compiled when `host_machine.system() == 'darwin'`.
5. **Write nim FFI bindings** in `src/plugins/macho.nim` that call
   into the C API with chalk's existing `FileStringStream` / `string`
   types on the boundary.
6. **Write `src/plugins/codecMacho.nim`** paralleling `codecElf.nim`:
   `machoScan` reads the LC_NOTE; `machoHandleWrite` adds/replaces
   it; `getUnchalkedHash` computes the SHA-256 of the rebuilt binary
   with the chalk LC_NOTE removed.
7. **Register the codec** in `src/plugin_load.nim` (only on
   `defined(macosx)`) and add the priority entry to
   `src/configs/base_plugins.c4m` at `priority: 1` (one before the
   existing `macos` codec at priority 2). On parse failure, fat
   binaries we don't yet handle, real-cert signed binaries, etc.,
   the codec returns `none()` from `scan` and the shell-wrapper
   codec at priority 2 picks up.

### Costs of this approach

- **Binary size**: chalk grows by ~150KB compiled (Mach-O parser
  only, no n00b). Today's chalk is 13MB → +1%. Negligible.
- **Build complexity**: meson sub-build added for the carved C code,
  conditionally on macOS. Linux/Docker build is unchanged.
- **Maintenance**: chalk owns this code now. Bug fixes happen here,
  not upstream. Trade-off vs. external dependency: simpler builds,
  no transitive deps, but we're on the hook for any Mach-O format
  evolution that affects us.

### Alternatives considered

1. **Hand-write a Mach-O parser in nim from scratch.** Initially what
   I proposed. ~600–1000 lines of nim. Real risk of byte-offset bugs
   that silently corrupt binaries. Rejected: lief-c already exists
   in C and is well-tested on real Mach-Os; carving from it is
   strictly safer than rewriting in nim.
2. **Wrap lief-c as an external library.** Adds n00b runtime as a
   transitive dep, ~1–2MB to the binary, complicates the build
   matrix. Rejected: vendoring the subset is simpler and we
   control the surface.
3. **Use Apple's `vtool` / `install_name_tool` shell-out tricks.**
   No Apple CLI accepts LC_NOTE additions. Rejected.
4. **Trailing data after the binary, signed-out-of-band.** See "Why
   not other locations" above. Rejected.

Decision: vendor the Mach-O subset of lief-c into this repo, FFI
from nim.

## Codec semantics — `isOwnable`

`machoScan` returns `none()` (refuses to handle) when:

1. **Magic mismatch.** Not Mach-O at all → defer to other codecs.
2. **Fat binary.** lief-c handles fat parsing, but inserting LC_NOTE
   into each slice + handling per-slice signatures is enough new
   complexity that it's deferred to a follow-up PR. Detect FAT_MAGIC
   and refuse → wrapper handles. *Note: this means fat Mac binaries
   chalk-marked today get the script wrapper, same as before.*
3. **Existing real-cert code signature.** If `LC_CODE_SIGNATURE` is
   present and the embedded `EmbeddedSignatureBlob` contains a
   non-empty `CertificateBlob`, refuse — modifying would invalidate
   the signature, and we don't have the cert/key to re-sign. Wrapper
   handles. (User can `codesign --remove-signature` first if they
   want native marking.)
4. **Existing ad-hoc code signature.** If `LC_CODE_SIGNATURE` is
   present but the `CertificateBlob` is empty — the binary was
   ad-hoc signed (e.g. `codesign -s -` for local dev/iteration) —
   handle natively: strip the signature, insert LC_NOTE, shell out
   to `codesign -s -` to re-sign ad-hoc. Requires `codesign` to be
   present in PATH; if not, refuse.
5. **lief-c parse failure.** Bubble up to wrapper.

Otherwise (thin Mach-O, unsigned or ad-hoc signed) → handle natively.

## Codec semantics — `handleWrite`

To insert/update:

1. Parse via lief-c.
2. If existing `crashoverride.chalk` LC_NOTE present → remove it
   (call `lief_macho_remove_note`).
3. Add new LC_NOTE with the chalk-mark JSON payload
   (`lief_macho_add_note`).
4. Serialize via `lief_macho_build` to a `n00b_buffer_t`; copy bytes
   back over the input file (or write atomically via temp + rename).
5. If the original was ad-hoc signed, run
   `codesign --force --sign - <file>` to restore an ad-hoc signature
   over the new layout.

To unchalk:

1. Parse via lief-c.
2. Remove `crashoverride.chalk` LC_NOTE if present.
3. Serialize, write back, re-sign-if-ad-hoc.

To compute `getUnchalkedHash`:

1. Parse via lief-c.
2. On a deep copy of the parsed binary, remove the LC_NOTE.
3. Serialize the copy.
4. SHA-256 of the serialized bytes.

The hash is *layout-stable*: as long as lief-c's serializer is
deterministic with respect to load-command order (which it is —
serialization order matches the parsed `commands` array), repeated
runs produce the same hash.

## Edge cases

- **Mach-O with no slack between load commands and __text.** Not an
  issue: lief-c parses the whole binary and serializes it back out
  with fresh offsets. If the existing slack is too small for the new
  LC_NOTE, the serializer just lays out a binary with more space at
  the boundary. There is no "load commands don't fit" failure mode.
  This is a key advantage of the parse-mutate-rebuild approach over
  in-place mutation — no need to refuse based on file layout.
- **Mach-O with `LC_ENCRYPTION_INFO` (FairPlay-encrypted binaries).**
  These are App Store binaries; we won't see them in chalk's
  workflow. lief-c parses them; we just don't add a note to them.
  If we do, refuse → wrapper handles. (Realistically these would be
  caught by the "real cert signature" check first.)
- **Symbol stripping.** `strip` runs as part of `make release`. Strip
  preserves LC_NOTE (it has no symbol-table content), so
  insert-then-strip works. Strip-then-insert also works. Order is up
  to the build pipeline. Recommend: strip first, then insert chalk
  mark, then codesign. This is what the release-macos.sh pipeline
  will do.
- **Codesign re-validation.** After insertion+sign, validate via
  `codesign --verify --strict --verbose=2`. Add this to release
  pipeline as a smoke test.

## Test plan

A native parser/codec is the kind of code where corruption bugs are
silent and high-impact. Test fixtures must exist *before* the
implementation is trusted:

1. **Fixture binaries** (committed to `tests/fixtures/macho/`):
   - `thin-arm64-unsigned`: `clang -arch arm64 hello.c -o hello`,
     not codesigned.
   - `thin-arm64-adhoc`: same, then `codesign -s - hello`.
   - `thin-arm64-devid`: same, then `codesign -s "Developer ID
     Application: ..." hello`. (Won't commit — generated by test
     setup script that requires the user's keychain.)
   - `fat-arm64-x86_64-unsigned`: `lipo`'d together.
   - `thin-arm64-with-existing-lcnote`: a binary that already has a
     non-chalk LC_NOTE (e.g., from `dsymutil`).

2. **Parser tests:**
   - Parse each fixture, assert header fields match `otool -h` output.
   - Parse each fixture, list load commands, assert match `otool -l`.

3. **Codec tests:**
   - For each fixture (except devid), `machoScan → machoHandleWrite
     → machoScan` round-trip; assert mark is readable.
   - Assert binary still runs after marking (`./marked-hello` → "hello\n").
   - Assert `codesign --verify` passes on ad-hoc fixture after
     mark+resign.
   - Assert devid fixture: `machoScan` returns `none()` (refuses),
     wrapper takes over.
   - Assert fat fixture: same — refuses, wrapper takes over.
   - Unchalk round-trip: `mark → unchalk → bytes match original`
     for unsigned fixture (binary should be byte-identical to
     pre-mark).
   - Unchalk hash: `getUnchalkedHash(marked) == getUnchalkedHash(unmarked)`.

4. **Notarize-on-CI smoke test (manual, gated on tag):**
   - Build chalk locally via `make release` (with codecMacho enabled,
     produces a real Mach-O without script wrapper).
   - Sign with `Developer ID Application`.
   - Notarize via `xcrun notarytool submit --wait`.
   - Assert: status `Accepted`.

## Rollout

1. **PR 1: this design doc.** Get sign-off on approach.
2. **PR 2: vendor Mach-O subset.** Carve from `~/vibe/lief/`
   (Mach-O code + minimum n00b transitive deps), add LC_NOTE
   helpers, add meson sub-build, build + run as standalone C binary
   against fixture Mach-Os. No nim or chalk integration yet —
   proves the carved code is correct in isolation. **Pre-PR
   decision: assess size of n00b carve. If trivial, ship as-is.
   If large, do an n00b-strip pass that retypes API surface to
   plain C.**
3. **PR 3: nim FFI bindings.** `src/plugins/macho.nim` wraps the
   vendored C library. Nim-side unit tests using fixture binaries
   from `tests/fixtures/macho/`.
4. **PR 4: chalk codec wiring.** `src/plugins/codecMacho.nim`,
   plugin_load.nim registration, base_plugins.c4m priority entry.
   Build-system glue to link the vendored static lib.
5. **PR 5: macOS release pipeline.** `scripts/release-macos.sh`
   already builds, signs, notarizes, and ships a pkg — what changes
   is just *what* `chalk load default` produces during build.  Today
   it script-wraps; with the native codec it inserts an LC_NOTE.
   Sign / notarize / pkg flow stays the same.  The release script
   gets a defensive sanity check: refuse to sign if the input isn't
   a Mach-O (catches a regression where the native codec silently
   fell back to the wrapper).

PRs 3 and 4 can be developed sequentially after PR 2 lands. PR 5
depends on PR 4.

## Open questions

1. **Does lief-c have an upstream we should be PRing the LC_NOTE
   helpers to, or is `~/vibe/lief/` the canonical home?** If it's
   private/local, I'll just edit it directly.
2. **Build-system integration**: chalk uses nimble + meson-built
   prebuilt static libs in `~/.local/c0/libs/`. Where should
   `liblief.a` and `libn00b.a` land — same convention?
3. **Do we want fat-binary support in PR 4, or a follow-up PR 6?**
   Currently planned as follow-up. Adds ~150 LOC and ~5 fixtures.
4. **Behavior when chalk runs on Linux against a Mach-O file**
   (cross-platform marking — possible if a Linux user has a Mac
   binary they want to chalk-mark). codecMacho is registered
   regardless of host OS, so it would handle. The `codesign`
   shell-out in the ad-hoc path would fail on Linux (no codesign
   binary). Treatment: detect codesign absence at handleWrite time,
   if needed, refuse → wrapper handles. **Confirm OK.**

## Non-goals

- **Replacing `codecMacOs.nim` (the script wrapper).** The wrapper
  remains as a fallback for binaries we refuse to handle natively.
  Long-term, if the native codec proves robust enough, we can
  consider deprecating the wrapper, but that's a separate decision.
- **Implementing our own codesigning**. We shell out to Apple's
  `codesign` binary. Reimplementing codesigning in nim is far out of
  scope.
- **Fat binary support in the first PR.** Deferred to a follow-up.

