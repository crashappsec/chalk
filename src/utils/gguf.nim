##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Nim FFI bindings for the GGUF codec under src/codecs/gguf/.
## Library glue, not a codec itself — codecGguf.nim imports this
## module to do parse / read / mark / unmark / unchalked-hash.
##
## See src/codecs/gguf/include/gguf.h for the API contract.

import std/[
  os,
]
import pkg/[
  nimutils/logging,
]

const
  ggufIncDir = currentSourcePath.parentDir.parentDir &
               "/codecs/gguf/include"
  ggufCFlags = "-std=c23 -I" & ggufIncDir

{.passc: "-I" & ggufIncDir.}

{.compile("../codecs/gguf/src/gguf.c", ggufCFlags).}

# ---------------------------------------------------------------------------
# Opaque handle and status enum.
# ---------------------------------------------------------------------------

type
  ChalkGgufHandle* = pointer

  ChalkGgufStatus* {.size: sizeof(cint).} = enum
    cgInternal    = -7
    cgNoChalk     = -6
    cgBadKv       = -5
    cgBadVersion  = -4
    cgBadMagic    = -3
    cgTruncated   = -2
    cgNull        = -1
    cgOk          = 0

# ---------------------------------------------------------------------------
# C entry points.
# ---------------------------------------------------------------------------

proc chalk_gguf_parse(bytes: ptr uint8, length: csize_t): ChalkGgufHandle
  {.importc, cdecl, header: "gguf.h".}

proc chalk_gguf_free(g: ChalkGgufHandle)
  {.importc, cdecl, header: "gguf.h".}

proc chalk_gguf_get_payload(g: ChalkGgufHandle,
                            outSize: ptr csize_t): cstring
  {.importc, cdecl, header: "gguf.h".}

proc chalk_gguf_set_chalk(g: ChalkGgufHandle,
                          mark: cstring, markLen: csize_t): cint
  {.importc, cdecl, header: "gguf.h".}

proc chalk_gguf_remove_chalk(g: ChalkGgufHandle): cint
  {.importc, cdecl, header: "gguf.h".}

proc chalk_gguf_get_buffer(g: ChalkGgufHandle,
                           outSize: ptr csize_t): pointer
  {.importc, cdecl, header: "gguf.h".}

proc chalk_gguf_unchalked_hash(g: ChalkGgufHandle, outHex: cstring): cint
  {.importc, cdecl, header: "gguf.h".}

# ---------------------------------------------------------------------------
# Diagnostic override.
# ---------------------------------------------------------------------------

proc chalk_gguf_warn(msg: cstring) {.cdecl, exportc.} =
  warn("chalk_gguf: " & $msg)

# ---------------------------------------------------------------------------
# Public Nim API
# ---------------------------------------------------------------------------

const
  GgufExt*    = ".gguf"
  GgufMagic*  = "GGUF"

type
  ParsedGguf* = ref object
    handle: ChalkGgufHandle

proc finalizeParsed(p: ParsedGguf) =
  if p != nil and p.handle != nil:
    chalk_gguf_free(p.handle)
    p.handle = nil

proc parseGguf*(bytes: string): ParsedGguf =
  ## Parse a GGUF file from raw bytes.  Returns nil on parse failure
  ## (truncated, bad magic, unsupported version, malformed KV
  ## section).  The C side copies the input bytes.
  if bytes.len < 24:
    return nil
  let h = chalk_gguf_parse(cast[ptr uint8](unsafeAddr bytes[0]),
                           bytes.len.csize_t)
  if h == nil:
    return nil
  new(result, finalizeParsed)
  result.handle = h

proc isOk(c: cint): bool {.inline.} = c == 0

proc getChalkPayload*(self: ParsedGguf): string =
  ## Return the chalk mark payload as a Nim string, or "" if no
  ## mark is present.  The C side returns a borrowed pointer; we copy.
  if self == nil or self.handle == nil:
    return ""
  var size: csize_t = 0
  let p = chalk_gguf_get_payload(self.handle, addr size)
  if p == nil:
    return ""
  result = newString(size.int)
  if size > 0:
    copyMem(addr result[0], p, size.int)

proc setChalk*(self: ParsedGguf, mark: string): ChalkGgufStatus =
  ## Insert or replace `chalk.mark` (and recompute alignment padding).
  if self == nil or self.handle == nil:
    return cgNull
  let mp = if mark.len == 0: cstring(nil) else: cstring(mark)
  result = ChalkGgufStatus(chalk_gguf_set_chalk(self.handle, mp,
                                                mark.len.csize_t))

proc removeChalk*(self: ParsedGguf): ChalkGgufStatus =
  ## Remove `chalk.mark` (and recompute padding).  cgNoChalk if absent.
  if self == nil or self.handle == nil:
    return cgNull
  result = ChalkGgufStatus(chalk_gguf_remove_chalk(self.handle))

proc getMutatedBytes*(self: ParsedGguf): string =
  ## Retrieve the (possibly mutated) raw bytes for write-back.
  if self == nil or self.handle == nil:
    return ""
  var size: csize_t = 0
  let p = chalk_gguf_get_buffer(self.handle, addr size)
  if p == nil or size == 0:
    return ""
  result = newString(size.int)
  copyMem(addr result[0], p, size.int)

proc unchalkedHash*(self: ParsedGguf): string =
  ## SHA-256 hex of the canonical (chalk-removed) form.  Stable
  ## across re-marks.  "" on error.
  if self == nil or self.handle == nil:
    return ""
  var hex = newString(65)
  hex.setLen(65)
  let st = chalk_gguf_unchalked_hash(self.handle, hex.cstring)
  if not st.isOk:
    return ""
  hex.setLen(64)
  result = hex
