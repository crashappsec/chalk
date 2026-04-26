# Native Mach-O codec

Chalk's macOS codec marks Mach-O binaries natively — modify the
binary in place, leave it a real Mach-O. Apple's notary accepts the
result; `codesign --verify --strict` passes; `dyld` ignores our
addition; `strip` preserves it.

The earlier script-wrapper codec (`src/plugins/codecMacOs.nim`)
remains as a fallback when this codec refuses an artifact.

## How marks are stored

We use Apple's `LC_NOTE` load command (0x31), the blessed mechanism
for tool-specific Mach-O metadata. The `data_owner` field is set to
`"chalk"` (NUL-padded to 16 bytes); the `offset`/`size` fields
point at the chalk-mark JSON appended at the end of the
`__LINKEDIT` segment.

Format of the JSON is unchanged from what the script-wrapper codec
writes today — existing `chalk extract` consumers keep working
across both mark styles.

## What this codec refuses

When `scan` returns `none()`, the script-wrapper codec at priority
2 picks up. We refuse:

1. **Files that aren't Mach-O.** Magic mismatch.
2. **Fat / universal binaries.** Deferred to a follow-up; FAT_MAGIC
   detected and refused.
3. **Real-cert (Developer ID / CMS) signed binaries that aren't
   already chalked.** Mutating would invalidate the signature, and
   we don't have the cert/key to re-sign. The wrapper handles. (If
   such a binary IS already chalked, scan claims it for extract
   only — handleWrite still refuses.)
4. **Malformed code signatures.** Refuse defensively.
5. **Insufficient load-command slack.** Adding the `LC_NOTE`
   command needs 40 bytes of slack between the end of the existing
   load commands and the start of the first section. Most compilers
   leave plenty; add `-Wl,-headerpad,0x1000` to the link line if
   you find a binary that doesn't.

Otherwise (thin Mach-O, unsigned or ad-hoc-signed) → handle natively.

## Mutation flow

Mirrors `src/plugins/elf.nim`'s in-place approach: parse to find
offsets, splice raw bytes inside the stream buffer, patch a few
header integer fields, write the file back.

Apple's `codesign` is fragile about layout: re-signing on top of an
existing signature, or appending data past `__LINKEDIT.fileoff +
filesize`, both produce binaries that fail `--verify --strict`
even though they run. The codec follows the only sequence that
works:

1. Strip the existing signature (truncate the sig blob, drop
   `LC_CODE_SIGNATURE`, shrink `__LINKEDIT.filesize`).
2. Append the chalk payload at the new `__LINKEDIT`-end; grow
   `__LINKEDIT.filesize`/`vmsize` to cover.
3. Insert the `LC_NOTE` in load-command slack; patch
   `mh_header.ncmds` and `sizeofcmds`.
4. Shell out to `codesign --force --sign -` to lay down a fresh
   ad-hoc signature past our payload.

Release pipelines re-sign with `Developer ID Application` over the
chalked-and-ad-hoc-signed binary; that's a flat replace and works
fine.

For unchalking (`enc = none`) the same flow runs in reverse.

## Unchalked hash

Mirrors `elf.nim`'s `getUnchalkedHash` semantics: marked and
unmarked binaries canonicalize to the same byte sequence — strip
signature, strip any existing chalk note, insert a canonical 32-byte
zero-payload chalk `LC_NOTE` — and SHA-256 of the canonical bytes
is the unchalked hash. Re-marks with payloads of any size produce
the same hash.

## Layout in the repo

| Path                           | What                                                                                                                                                      |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/codecs/macho/`            | C library adapted from LIEF for the parser + LC_NOTE primitives. Standalone Makefile + smoke tests. Plain C23, OpenSSL libcrypto for SHA-256.             |
| `src/utils/macho.nim`          | FFI bindings. Compiles the C sources via `{.compile.}` pragmas. `chalk_macho_warn` overrides the C-side weak default to route into nim's `warn` template. |
| `src/plugins/codecMacho.nim`   | The codec itself. `scan` / `handleWrite` / `getUnchalkedHash` / `ctArtCallback` / `rtArtCallback`.                                                        |
| `src/plugin_load.nim`          | Registers `codecMacho` ahead of `codecMacOs`.                                                                                                             |
| `src/configs/base_plugins.c4m` | Native at priority 1; wrapper at priority 2.                                                                                                              |
| `scripts/release-macos.sh`     | Build → strip → `chalk load default` → codesign with Developer ID → notarize → pkg → staple.                                                              |

## Cross-platform

The C library has no macOS-only dependencies (libcrypto for
SHA-256, plain POSIX for file I/O). The codec is registered as
native on both macOS and Linux, so chalk on Linux can:

- Read both wrapper and native chalk marks on Mac binaries.
- Write native marks on unsigned Mach-Os (warns about no
  `codesign` in PATH; binary won't run on macOS without re-signing
  there).

## Open follow-ups

- Fat / universal binaries. Currently refused; native handling
  needs per-slice mark insertion plus per-slice signature
  considerations.
- Better error messages from `codesign` failures during ad-hoc
  re-sign — currently we surface the raw stderr.
