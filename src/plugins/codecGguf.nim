##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Native GGUF codec.  Marks `.gguf` files by inserting a string KV
## pair `chalk.mark` into the file's metadata section, with alignment
## padding recomputed so tensor data offsets remain valid.  See
## docs/design-model-codecs.md.
##
## Refuses (returns none → fallback codec at lower priority) when:
##   - the file is shorter than the GGUF header
##   - magic is not "GGUF"
##   - version is not 2 or 3
##   - the KV section or tensor info parse fails

import std/[
  options,
  os,
  strutils,
]

import ".."/[
  chalkjson,
  plugin_api,
  run_management,
  types,
  utils/files,
  utils/gguf,
]

type
  GgufCache = ref object of RootRef
    parsed: ParsedGguf

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

proc ggufScan*(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  if not path.toLowerAscii().endsWith(GgufExt):
    return none(ChalkObj)

  let bytes =
    try:
      readFile(path)
    except IOError, OSError:
      return none(ChalkObj)

  if bytes.len < 24 or bytes[0 .. 3] != GgufMagic:
    return none(ChalkObj)

  let parsed = parseGguf(bytes)
  if parsed == nil:
    trace(path & ": GGUF parse failed; deferring to fallback codec")
    return none(ChalkObj)

  let cache = GgufCache(parsed: parsed)

  var dict: ChalkDict
  var marked = false

  let existing = parsed.getChalkPayload()
  if existing != "":
    if existing.find(magicUTF8) == -1:
      warn(path & ": chalk.mark KV present but missing magic; " &
           "treating as unmarked")
    else:
      dict   = extractOneChalkJson(existing, path)
      marked = dict != nil

  let chalk = newChalk(
    name         = path,
    fsRef        = path,
    codec        = self,
    resourceType = {ResourceFile},
    cache        = cache,
    extract      = dict,
    marked       = marked,
  )

  return some(chalk)

# ---------------------------------------------------------------------------
# getUnchalkedHash
# ---------------------------------------------------------------------------

proc ggufGetUnchalkedHash*(self: Plugin, chalk: ChalkObj):
                           Option[string] {.cdecl.} =
  if chalk.cachedUnchalkedHash != "":
    return some(chalk.cachedUnchalkedHash)

  let cache = GgufCache(chalk.cache)
  if cache == nil or cache.parsed == nil:
    return none(string)

  let hex = cache.parsed.unchalkedHash()
  if hex == "":
    error(chalk.name & ": GGUF unchalked-hash failed")
    return none(string)

  chalk.cachedUnchalkedHash = hex
  return some(hex)

# ---------------------------------------------------------------------------
# handleWrite
# ---------------------------------------------------------------------------

proc ggufHandleWrite*(self: Plugin, chalk: ChalkObj,
                      enc: Option[string]) {.cdecl.} =
  let cache = GgufCache(chalk.cache)
  if cache == nil or cache.parsed == nil:
    error(chalk.name & ": no parsed GGUF state")
    chalk.opFailed = true
    return

  discard chalk.callGetUnchalkedHash()

  let st =
    if enc.isSome() and enc.get().len > 0:
      cache.parsed.setChalk(enc.get())
    else:
      let r = cache.parsed.removeChalk()
      if r == cgNoChalk:
        cgOk
      else:
        r

  if st != cgOk:
    warn(chalk.name & ": GGUF write failed (status " & $st & ")")
    chalk.opFailed = true
    return

  let mutated = cache.parsed.getMutatedBytes()
  if mutated.len == 0:
    error(chalk.name & ": empty mutated bytes")
    chalk.opFailed = true
    return

  if not chalk.fsRef.replaceFileContents(mutated):
    error(chalk.name & ": replaceFileContents failed")
    chalk.opFailed = true

# ---------------------------------------------------------------------------
# Metadata callbacks
# ---------------------------------------------------------------------------

proc ggufGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                   ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("ARTIFACT_TYPE", artTypeGguf)

proc ggufGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj,
                                 ins: bool): ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeGguf)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc loadCodecGguf*() =
  newCodec(
    "gguf",
    nativeObjPlatforms = @["macosx", "linux"],
    scan             = ScanCb(ggufScan),
    handleWrite      = HandleWriteCb(ggufHandleWrite),
    getUnchalkedHash = UnchalkedHashCb(ggufGetUnchalkedHash),
    ctArtCallback    = ChalkTimeArtifactCb(ggufGetChalkTimeArtifactInfo),
    rtArtCallback    = RunTimeArtifactCb(ggufGetRunTimeArtifactInfo),
  )
