##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Nim FFI bindings for the carved Mach-O codec under
## src/codecs/macho/.  Library glue, not a codec — codecMacho.nim
## imports this module to do the actual chalk-mark insert/extract.
##
## The C side does in-place mutation of a Mach-O binary's raw bytes;
## these wrappers expose a small, allocation-light surface to nim:
## parse from a `string`, run the helper, hand back a `string` of the
## (possibly mutated) bytes for the caller to write to disk.
##
## See src/codecs/macho/include/chalk_macho.h for the API contract.

import std/[
  os,
]
import pkg/[
  nimutils/logging,
]

# ---------------------------------------------------------------------------
# Compile the carved C sources directly into the chalk binary.  The
# carved code is plain C23, no platform-specific dependencies — chalk
# can mark Mach-O binaries from Linux too.  libcrypto is statically
# linked via config.nims.
# ---------------------------------------------------------------------------

# The carved C sources are C23 (use nullptr, auto-typed locals, etc.).
# Chalk's main build doesn't pass -std=c23 globally; we apply it
# per-file via the call form of {.compile("file.c", "extra-args").},
# which threads extraArgs into the per-file clang invocation.
const
  machoIncDir = currentSourcePath.parentDir.parentDir &
                "/codecs/macho/include"
  machoCFlags = "-std=c23 -I" & machoIncDir

# nim-generated C for this module also #includes our headers (via
# the {.header.} pragmas on imported types), so put the include path
# in the module-level passc too.  -std=c23 doesn't go in passc — the
# nim-emitted glue is C99 and would not survive C23's stricter rules.
{.passc: "-I" & machoIncDir.}

{.compile("../codecs/macho/src/n00b_shim.c",   machoCFlags).}
{.compile("../codecs/macho/src/macho_stream.c", machoCFlags).}
{.compile("../codecs/macho/src/macho.c",        machoCFlags).}
{.compile("../codecs/macho/src/chalk_macho.c",  machoCFlags).}

# ---------------------------------------------------------------------------
# Opaque C handles.  Nim doesn't need to know the layout — all access
# goes through chalk_macho_* helpers below.
# ---------------------------------------------------------------------------

type
  MachoStream*   = pointer
  MachoBinary*   = pointer
  MachoFat*      = pointer

  ## Mirrors the chalk_macho_status_t enum.
  ChalkMachoStatus* {.size: sizeof(cint).} = enum
    cmInternal      = -7
    cmBadNote       = -6
    cmFat           = -5
    cmNoChalkNote   = -4
    cmNoLcSlack     = -3
    cmTooLarge      = -2
    cmNullBinary    = -1
    cmOk            = 0

  ## Mirrors chalk_macho_sig_kind_t.
  ChalkMachoSigKind* {.size: sizeof(cint).} = enum
    csNone      = 0  ## no LC_CODE_SIGNATURE
    csAdhoc     = 1  ## CodeDirectory present, CMS empty
    csRealCert  = 2  ## CMS / Developer ID signature
    csMalformed = 3  ## LC present but blob unreadable

  ## A parsed Mach-O.  Owns the underlying C-side parse arena (the
  ## `fat` pointer); when this nim ref is collected, `=destroy` calls
  ## chalk_macho_free, which walks the fat container and releases
  ## commands, segments, raw_data buffers, the stream, and the
  ## backing byte storage.
  ##
  ## `bin` is a borrowed pointer into one slice of the fat container
  ## (the first slice, since chalk doesn't yet handle fat).  Do NOT
  ## use it after this ref is destroyed.
  ParsedMacho* = ref object
    fat: MachoFat       ## Owned — freed in =destroy.
    bin*: MachoBinary   ## Borrowed from fat.binaries[0].

# ---------------------------------------------------------------------------
# C function imports
#
# n00b_shim's buffer/stream constructors are not exposed to nim — we
# go through macho_stream_from_file for parse and chalk_macho_* for
# everything else.  But we need the parse entry point that takes a
# byte buffer (not a path), since chalk normalises files via its
# FileStringStream first.
# ---------------------------------------------------------------------------

# Pull the C headers in directly so nim's forward declarations match
# what's in n00b_shim.h / macho.h / chalk_macho.h.  Without `header:`,
# nim emits its own (often subtly different) prototypes and clang
# rejects with "conflicting types".

# n00b_shim primitives we need to construct a stream from in-memory bytes.
proc n00b_buffer_from_bytes(bytes: cstring, length: int64): pointer
  {.importc, cdecl, header: "n00b_shim.h".}
proc macho_stream_new(buf: pointer): MachoStream
  {.importc, cdecl, header: "macho_stream.h".}

# Result carrier — must match n00b_shim.h.
type
  N00bResult {.importc: "n00b_result_carrier_t",
               header: "n00b_shim.h", bycopy.} = object
    is_err: bool
    err_code: cint
    v: uint64

proc macho_parse(stream: MachoStream): N00bResult
  {.importc, cdecl, header: "macho.h".}

# Fat binary container — only fields chalk needs.
type
  MachoFatStruct {.importc: "struct macho_fat",
                   header: "macho.h", bycopy.} = object
    binaries: ptr UncheckedArray[MachoBinary]
    count:    uint32

# chalk_macho_* in-place mutation API.
proc chalk_macho_add_note(bin: MachoBinary,
                          payload: ptr UncheckedArray[byte],
                          payloadSize: csize_t): cint
  {.importc, cdecl, header: "chalk_macho.h".}

proc chalk_macho_remove_note(bin: MachoBinary): cint
  {.importc, cdecl, header: "chalk_macho.h".}

proc chalk_macho_unchalked_hash(bin: MachoBinary,
                                outHex: cstring): cint
  {.importc, cdecl, header: "chalk_macho.h".}

proc chalk_macho_get_buffer(bin: MachoBinary,
                            outSize: ptr csize_t): pointer
  {.importc, cdecl, header: "chalk_macho.h".}

# Read API.
type
  ChalkMachoNote {.importc: "chalk_macho_note_t",
                   header: "chalk_macho.h", bycopy.} = object
    data_owner: array[17, char]
    payload_offset: uint64
    payload_size: uint64
    payload: pointer

proc chalk_macho_get_notes(bin: MachoBinary,
                           outCount: ptr csize_t): ptr ChalkMachoNote
  {.importc, cdecl, header: "chalk_macho.h".}

proc chalk_macho_get_chalk_payload(bin: MachoBinary,
                                   outSize: ptr csize_t): pointer
  {.importc, cdecl, header: "chalk_macho.h".}

proc chalk_macho_free(fat: MachoFat)
  {.importc, cdecl, header: "macho.h".}

proc chalk_macho_signature_kind(bin: MachoBinary): cint
  {.importc, cdecl, header: "chalk_macho.h".}

proc chalk_macho_strip_signature(bin: MachoBinary): cint
  {.importc, cdecl, header: "chalk_macho.h".}

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

# ---------------------------------------------------------------------------
# Warn callback — strong override of the weak C default in
# chalk_macho.c.  Forwarded to chalk's logging template.
# ---------------------------------------------------------------------------

proc chalk_macho_warn(msg: cstring) {.cdecl, exportc.} =
  warn("chalk_macho: " & $msg)

# ---------------------------------------------------------------------------
# Public nim API
# ---------------------------------------------------------------------------

const
  ## Magic bytes for any Mach-O 64-bit (LE or BE).  Caller can sniff
  ## these before bothering with parseMacho().
  MachoMagicLE* = "\xCF\xFA\xED\xFE"  ## MH_MAGIC_64 little-endian on disk
  MachoMagicBE* = "\xFE\xED\xFA\xCF"  ## MH_CIGAM_64 (other endian)
  MachoFatMagic* = "\xCA\xFE\xBA\xBE" ## FAT_MAGIC

proc isMachoMagic*(prefix: openArray[char]): bool =
  ## True if the leading 4 bytes look like Mach-O (thin or fat).
  if prefix.len < 4: return false
  var m = newString(4)
  for i in 0 ..< 4:
    m[i] = prefix[i]
  result = m == MachoMagicLE or m == MachoMagicBE or m == MachoFatMagic

proc finalizeParsedMacho(p: ParsedMacho) =
  ## Walk the C parse arena and release everything (commands +
  ## raw_data, segments, sections, stream, buffer, byte storage).
  ## Defensive: chalk_macho_free is NULL-safe.
  if p != nil and p.fat != nil:
    chalk_macho_free(p.fat)
    p.fat = nil
    p.bin = nil

proc parseMacho*(bytes: string): ParsedMacho =
  ## Parse a Mach-O binary from raw bytes.  Returns nil on failure.
  ##
  ## The C side does its own copy of `bytes` into a buffer it owns
  ## (via n00b_buffer_from_bytes); after this returns, `bytes` is no
  ## longer referenced.  All later mutation operations (addChalkNote,
  ## removeChalkNote, getMutatedBytes, etc.) operate on the C-owned
  ## copy.
  ##
  ## When the returned ref is collected, =destroy frees the parse
  ## arena.  No explicit teardown call needed.
  if bytes.len == 0:
    return nil

  let buf = n00b_buffer_from_bytes(bytes.cstring, bytes.len.int64)
  if buf == nil:
    return nil

  let stream = macho_stream_new(buf)
  if stream == nil:
    return nil

  let r = macho_parse(stream)
  if r.is_err:
    return nil

  let fat = cast[ptr MachoFatStruct](r.v)
  if fat == nil or fat.count == 0:
    if fat != nil:
      chalk_macho_free(cast[MachoFat](fat))
    return nil

  # We only handle the first slice; fat Mach-O is deferred (the C
  # side rejects mutation with cmFat).  The MachoBinary pointer is
  # borrowed from the fat container.
  new(result, finalizeParsedMacho)
  result.fat = cast[MachoFat](fat)
  result.bin = fat.binaries[0]

proc isOk(c: cint): bool {.inline.} = c == 0

proc stripSignature*(self: ParsedMacho): ChalkMachoStatus =
  ## Strip the existing code signature in place.  Required as the
  ## first step before addChalkNote on a binary that has any
  ## signature (linker-applied ad-hoc, codesign -s -, etc.) — Apple's
  ## codesign refuses to add a fresh signature past the chalk
  ## payload otherwise.  No-op if the binary is unsigned.
  if self == nil or self.bin == nil:
    return cmNullBinary
  result = ChalkMachoStatus(chalk_macho_strip_signature(self.bin))

proc addChalkNote*(self: ParsedMacho, payload: string): ChalkMachoStatus =
  ## Insert or replace the chalk LC_NOTE.  Caller must have called
  ## stripSignature first if the binary had any code signature.
  ## After a successful call use `getMutatedBytes` to retrieve the
  ## new file contents (and optionally pass to `codesign --force
  ## --sign -` to add a fresh signature past the payload).
  if self == nil or self.bin == nil:
    return cmNullBinary

  let pBuf =
    if payload.len == 0:
      cast[ptr UncheckedArray[byte]](nil)
    else:
      cast[ptr UncheckedArray[byte]](unsafeAddr payload[0])

  result = ChalkMachoStatus(chalk_macho_add_note(self.bin, pBuf,
                                                 payload.len.csize_t))

proc removeChalkNote*(self: ParsedMacho): ChalkMachoStatus =
  ## Splice out the chalk LC_NOTE.  cmNoChalkNote if absent.
  if self == nil or self.bin == nil:
    return cmNullBinary
  result = ChalkMachoStatus(chalk_macho_remove_note(self.bin))

proc signatureKind*(self: ParsedMacho): ChalkMachoSigKind =
  ## Classify the binary's code signature.  csNone / csAdhoc /
  ## csRealCert / csMalformed.  The codec uses this to decide
  ## whether to mutate in place (none/adhoc) or defer to the
  ## script-wrapper codec (real_cert/malformed).
  if self == nil or self.bin == nil:
    return csNone
  result = ChalkMachoSigKind(chalk_macho_signature_kind(self.bin))

proc unchalkedHash*(self: ParsedMacho): string =
  ## SHA-256 hex of the canonicalized binary (32-byte zero chalk
  ## payload form, mirroring elf.nim's getUnchalkedHash).  Returns ""
  ## on error.
  if self == nil or self.bin == nil:
    return ""

  var hex = newString(64)
  let st = chalk_macho_unchalked_hash(self.bin, hex.cstring)
  if not st.isOk:
    return ""

  result = hex

proc getMutatedBytes*(self: ParsedMacho): string =
  ## Retrieve the (possibly mutated) raw bytes for write-back.
  ## Returns "" on error.  The returned string is a fresh nim-owned
  ## copy — safe to write to disk and free `self` afterwards.
  if self == nil or self.bin == nil:
    return ""

  var size: csize_t = 0
  let p = chalk_macho_get_buffer(self.bin, addr size)
  if p == nil or size == 0:
    return ""

  result = newString(size.int)
  copyMem(addr result[0], p, size.int)

proc getChalkPayload*(self: ParsedMacho): string =
  ## Return the chalk-mark payload, or "" if absent.
  if self == nil or self.bin == nil:
    return ""

  var size: csize_t = 0
  let p = chalk_macho_get_chalk_payload(self.bin, addr size)
  if p == nil:
    return ""

  result = newString(size.int)
  if size > 0:
    copyMem(addr result[0], p, size.int)
  c_free(p)

iterator notes*(self: ParsedMacho): tuple[owner: string,
                                           payload: string] =
  ## Yield (data_owner, payload) for every LC_NOTE.  The payload is
  ## a copy — caller is free to retain it.
  if self != nil and self.bin != nil:
    var count: csize_t = 0
    let arr = chalk_macho_get_notes(self.bin, addr count)
    if arr != nil:
      try:
        for i in 0 ..< count.int:
          let n = cast[ptr UncheckedArray[ChalkMachoNote]](arr)[i]
          var owner = newString(0)
          for c in n.data_owner:
            if c == '\0': break
            owner.add(c)
          var pay = newString(n.payload_size.int)
          if n.payload != nil and n.payload_size > 0:
            copyMem(addr pay[0], n.payload, n.payload_size.int)
          yield (owner, pay)
      finally:
        c_free(arr)
