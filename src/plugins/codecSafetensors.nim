##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Native SafeTensors codec.  Marks `.safetensors` files by inserting
## a `chalk` key under `__metadata__` in the file's JSON header.  See
## docs/design-model-codecs.md.
##
## Refuses (returns none → next codec at lower priority) when:
##   - the file is shorter than the SafeTensors header preamble
##   - header_size is implausible / outside the file
##   - the JSON header doesn't parse as an object
##
## Otherwise: mutate in place, write back, no re-signing involved.

import std/[
  options,
  strutils,
]

import ".."/[
  chalkjson,
  plugin_api,
  run_management,
  types,
  utils/files,
  utils/safetensors,
]

type
  StCache = ref object of RootRef
    ## Per-artifact state held across scan → handleWrite calls.
    parsed:  ParsedSafetensors
    rawSize: int

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

proc stScan*(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  if not path.toLowerAscii().endsWith(SafetensorsExt):
    return none(ChalkObj)

  let bytes =
    try:
      readFile(path)
    except IOError, OSError:
      return none(ChalkObj)

  if bytes.len < 8:
    return none(ChalkObj)

  let parsed = parseSafetensors(bytes)
  if parsed == nil:
    trace(path & ": SafeTensors parse failed; deferring to fallback codec")
    return none(ChalkObj)

  let cache = StCache(
    parsed:  parsed,
    rawSize: bytes.len,
  )

  var dict: ChalkDict
  var marked = false

  let existing = parsed.getChalkPayload()
  if existing != "":
    if existing.find(magicUTF8) == -1:
      warn(path & ": __metadata__.chalk present but missing magic; " &
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

proc stGetUnchalkedHash*(self: Plugin, chalk: ChalkObj):
                         Option[string] {.cdecl.} =
  if chalk.cachedUnchalkedHash != "":
    return some(chalk.cachedUnchalkedHash)

  let cache = StCache(chalk.cache)
  if cache == nil or cache.parsed == nil:
    return none(string)

  let hex = cache.parsed.unchalkedHash()
  if hex == "":
    error(chalk.name & ": SafeTensors unchalked-hash failed")
    return none(string)

  chalk.cachedUnchalkedHash = hex
  return some(hex)

# ---------------------------------------------------------------------------
# handleWrite
# ---------------------------------------------------------------------------

proc stHandleWrite*(self: Plugin, chalk: ChalkObj,
                    enc: Option[string]) {.cdecl.} =
  let cache = StCache(chalk.cache)
  if cache == nil or cache.parsed == nil:
    error(chalk.name & ": no parsed SafeTensors state")
    chalk.opFailed = true
    return

  # Compute the unchalked hash before mutating.
  discard chalk.callGetUnchalkedHash()

  let st =
    if enc.isSome() and enc.get().len > 0:
      cache.parsed.setChalk(enc.get())
    else:
      let r = cache.parsed.removeChalk()
      if r == cstNoChalk:
        cstOk
      else:
        r

  if st != cstOk:
    warn(chalk.name & ": SafeTensors write failed (status " & $st & ")")
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

proc stGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                 ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("ARTIFACT_TYPE", artTypeSafetensors)

proc stGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj,
                               ins: bool): ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeSafetensors)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc loadCodecSafetensors*() =
  newCodec(
    "safetensors",
    nativeObjPlatforms = @["macosx", "linux"],
    scan             = ScanCb(stScan),
    handleWrite      = HandleWriteCb(stHandleWrite),
    getUnchalkedHash = UnchalkedHashCb(stGetUnchalkedHash),
    ctArtCallback    = ChalkTimeArtifactCb(stGetChalkTimeArtifactInfo),
    rtArtCallback    = RunTimeArtifactCb(stGetRunTimeArtifactInfo),
  )
