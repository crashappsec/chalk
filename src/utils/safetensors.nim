##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Nim FFI bindings for the SafeTensors codec under
## src/codecs/safetensors/.  Library glue, not a codec itself —
## codecSafetensors.nim imports this module to do parse / read / mark
## / unmark / unchalked-hash.
##
## See src/codecs/safetensors/include/safetensors.h for the API
## contract.  The C side does in-place mutation of an in-memory copy
## of the file bytes; this module wraps that for Nim string lifetimes.

import std/[
  os,
]
import pkg/[
  nimutils/logging,
]

# ---------------------------------------------------------------------------
# Compile the carved C sources directly into the chalk binary.  Same
# shape as src/utils/macho.nim — per-file -std=c23 via the call form
# of {.compile.}, with the include path set in passc for nim's emitted
# glue (which is C99).
# ---------------------------------------------------------------------------

const
  stIncDir = currentSourcePath.parentDir.parentDir &
             "/codecs/safetensors/include"
  stCFlags = "-std=c23 -I" & stIncDir

{.passc: "-I" & stIncDir.}

{.compile("../codecs/safetensors/src/safetensors.c", stCFlags).}

# ---------------------------------------------------------------------------
# Opaque handle and status enum (mirrors safetensors.h).
# ---------------------------------------------------------------------------

type
  ChalkStHandle* = pointer

  ChalkStStatus* {.size: sizeof(cint).} = enum
    cstInternal   = -6
    cstNoChalk    = -5
    cstNotObject  = -4
    cstBadHeader  = -3
    cstTruncated  = -2
    cstNull       = -1
    cstOk         = 0

# ---------------------------------------------------------------------------
# C entry points.
# ---------------------------------------------------------------------------

proc chalk_st_parse(bytes: ptr uint8, length: csize_t): ChalkStHandle
  {.importc, cdecl, header: "safetensors.h".}

proc chalk_st_free(st: ChalkStHandle)
  {.importc, cdecl, header: "safetensors.h".}

proc chalk_st_get_payload(st: ChalkStHandle, outSize: ptr csize_t): cstring
  {.importc, cdecl, header: "safetensors.h".}

proc chalk_st_set_chalk(st: ChalkStHandle,
                        mark: cstring, markLen: csize_t): cint
  {.importc, cdecl, header: "safetensors.h".}

proc chalk_st_remove_chalk(st: ChalkStHandle): cint
  {.importc, cdecl, header: "safetensors.h".}

proc chalk_st_get_buffer(st: ChalkStHandle,
                         outSize: ptr csize_t): pointer
  {.importc, cdecl, header: "safetensors.h".}

proc chalk_st_unchalked_hash(st: ChalkStHandle, outHex: cstring): cint
  {.importc, cdecl, header: "safetensors.h".}

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

# ---------------------------------------------------------------------------
# Diagnostic override — strong link-time replacement of the C-side
# weak fprintf default.  Routes into chalk's `warn` template.
# ---------------------------------------------------------------------------

proc chalk_st_warn(msg: cstring) {.cdecl, exportc.} =
  warn("chalk_st: " & $msg)

# ---------------------------------------------------------------------------
# Public Nim API
# ---------------------------------------------------------------------------

const
  ## SafeTensors files always begin with an 8-byte LE header_size.
  ## There is no magic per se; the codec sniffs by parsing.
  SafetensorsExt* = ".safetensors"

type
  ParsedSafetensors* = ref object
    ## Owns a parsed SafeTensors file.  =destroy frees the C-side
    ## handle.  The wrapped string returned by getBuffer is a fresh
    ## Nim copy — safe to write back independently of this ref.
    handle: ChalkStHandle

proc finalizeParsed(p: ParsedSafetensors) =
  if p != nil and p.handle != nil:
    chalk_st_free(p.handle)
    p.handle = nil

proc parseSafetensors*(bytes: string): ParsedSafetensors =
  ## Parse a SafeTensors file from raw bytes.  Returns nil on parse
  ## failure (truncated, malformed JSON header, header_size out of
  ## range).  The C side copies the input bytes; the caller's `bytes`
  ## is not retained.
  if bytes.len < 8:
    return nil
  let h = chalk_st_parse(cast[ptr uint8](unsafeAddr bytes[0]),
                         bytes.len.csize_t)
  if h == nil:
    return nil
  new(result, finalizeParsed)
  result.handle = h

proc isOk(c: cint): bool {.inline.} = c == 0

proc getChalkPayload*(self: ParsedSafetensors): string =
  ## Return the chalk mark payload as a Nim string, or "" if no
  ## mark is present.  The C side returns a malloc'd buffer; we copy
  ## and free.
  if self == nil or self.handle == nil:
    return ""
  var size: csize_t = 0
  let p = chalk_st_get_payload(self.handle, addr size)
  if p == nil:
    return ""
  result = newString(size.int)
  if size > 0:
    copyMem(addr result[0], p, size.int)
  c_free(cast[pointer](p))

proc setChalk*(self: ParsedSafetensors, mark: string): ChalkStStatus =
  ## Insert or replace the chalk mark in the header.
  if self == nil or self.handle == nil:
    return cstNull
  let mp = if mark.len == 0: cstring(nil) else: cstring(mark)
  result = ChalkStStatus(chalk_st_set_chalk(self.handle, mp,
                                            mark.len.csize_t))

proc removeChalk*(self: ParsedSafetensors): ChalkStStatus =
  ## Remove the chalk mark.  cstNoChalk if there is no mark to remove.
  if self == nil or self.handle == nil:
    return cstNull
  result = ChalkStStatus(chalk_st_remove_chalk(self.handle))

proc getMutatedBytes*(self: ParsedSafetensors): string =
  ## Retrieve the (possibly mutated) raw bytes for write-back.
  ## Returns "" on error.  The result is a fresh Nim-owned copy.
  if self == nil or self.handle == nil:
    return ""
  var size: csize_t = 0
  let p = chalk_st_get_buffer(self.handle, addr size)
  if p == nil or size == 0:
    return ""
  result = newString(size.int)
  copyMem(addr result[0], p, size.int)

proc unchalkedHash*(self: ParsedSafetensors): string =
  ## SHA-256 hex of the canonical (chalk-pair-removed) form.  Stable
  ## across re-marks.  "" on error.
  if self == nil or self.handle == nil:
    return ""
  var hex = newString(64)
  let st = chalk_st_unchalked_hash(self.handle, hex.cstring)
  if not st.isOk:
    return ""
  result = hex
