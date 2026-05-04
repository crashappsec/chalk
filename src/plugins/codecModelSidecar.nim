##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Last-resort codec for ML model file formats that can't be marked
## in-band.  Writes a `<path>.chalk` sidecar file alongside the
## artifact containing the mark JSON; reads the same file on extract.
##
## The codec is gated on a configured extension list
## (`sidecar_extensions`) — it is NOT a global fallthrough.  In the
## default config the list covers `.onnx` (no protobuf parser yet)
## and `.bin` (Ollama-style raw blobs).  Legacy pickle PyTorch
## checkpoints whose `.pt`/`.pth` files are not ZIP-shaped fall
## through `codecZip`'s scan and end up here too, since the
## extension list also names `pt` / `pth` as candidates for sidecar
## fallback.  Format-specific codecs run at higher priority and
## claim their formats first.

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
]

const sidecarSuffix = ".chalk"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc sidecarPath(path: string): string =
  path & sidecarSuffix

proc extensionMatches(path: string): bool =
  let ext = path.splitFile().ext.toLowerAscii()
  if ext.len < 2:
    return false
  let bare = ext[1 .. ^1]  # drop leading '.'
  for entry in attrGet[seq[string]]("sidecar_extensions"):
    if entry.toLowerAscii() == bare:
      return true
  return false

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

proc sidecarScan*(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  ## Claim files whose extension matches the sidecar list.  Higher-
  ## priority codecs (safetensors, gguf, zip) run first; if they
  ## refuse, this codec picks up.  We do NOT examine the file
  ## contents — a sibling .chalk file is the only signal of a prior
  ## mark.
  if not extensionMatches(path):
    return none(ChalkObj)
  if not fileExists(path):
    return none(ChalkObj)

  var dict: ChalkDict
  let sp = sidecarPath(path)
  withFileStream(sp, mode = fmRead, strict = false):
    if stream != nil:
      try:
        dict = extractOneChalkJson(stream, path)
      except:
        warn(path & ": sidecar present but could not parse; treating as unmarked")

  let chalk = newChalk(
    name         = path,
    fsRef        = path,
    codec        = self,
    resourceType = {ResourceFile},
    extract      = dict,
  )

  return some(chalk)

# ---------------------------------------------------------------------------
# getUnchalkedHash
# ---------------------------------------------------------------------------

proc sidecarGetUnchalkedHash*(self: Plugin, chalk: ChalkObj):
                              Option[string] {.cdecl.} =
  ## Sidecar marks live outside the artifact file itself, so the
  ## unchalked hash is the natural file SHA-256 — no canonicalization
  ## needed.
  if chalk.cachedUnchalkedHash != "":
    return some(chalk.cachedUnchalkedHash)
  let fss =
    try:
      newFileStringStream(chalk.fsRef)
    except:
      return none(string)
  let hex = fss.sha256Hex()
  chalk.cachedUnchalkedHash = hex
  return some(hex)

# ---------------------------------------------------------------------------
# handleWrite
# ---------------------------------------------------------------------------

proc sidecarHandleWrite*(self: Plugin, chalk: ChalkObj,
                         enc: Option[string]) {.cdecl.} =
  ## enc.isSome() with non-empty content → write the sidecar.
  ## enc.isNone() or empty → unchalk by removing any existing
  ## sidecar.  The artifact file itself is never touched.
  let sp = sidecarPath(chalk.fsRef)

  if enc.isSome() and enc.get().len > 0:
    var line = enc.get()
    if not line.endsWith("\n"):
      line.add("\n")
    if not tryToWriteFile(sp, line):
      error(chalk.name & ": could not write sidecar " & sp)
      chalk.opFailed = true
      return
  else:
    if fileExists(sp):
      try:
        removeFile(sp)
      except IOError, OSError:
        warn(chalk.name & ": could not remove sidecar " & sp & ": " &
             getCurrentExceptionMsg())

# ---------------------------------------------------------------------------
# Metadata callbacks
# ---------------------------------------------------------------------------

proc sidecarGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                      ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("ARTIFACT_TYPE", artTypeMLModel)

proc sidecarGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj,
                                    ins: bool): ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeMLModel)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc loadCodecModelSidecar*() =
  newCodec(
    "model_sidecar",
    scan             = ScanCb(sidecarScan),
    handleWrite      = HandleWriteCb(sidecarHandleWrite),
    getUnchalkedHash = UnchalkedHashCb(sidecarGetUnchalkedHash),
    ctArtCallback    = ChalkTimeArtifactCb(sidecarGetChalkTimeArtifactInfo),
    rtArtCallback    = RunTimeArtifactCb(sidecarGetRunTimeArtifactInfo),
  )
