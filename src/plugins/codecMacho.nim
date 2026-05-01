##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Native Mach-O codec.  Marks Mach-O binaries by inserting an
## LC_NOTE load command (data_owner == "chalk") with the chalk-mark
## JSON appended at end-of-file.  See docs/design-macho-codec.md.
##
## Refuses (returning none → wrapper codec at lower priority picks
## up):
##   - non-Mach-O files (magic mismatch)
##   - fat / universal binaries (deferred to a follow-up PR)
##   - real-cert-signed binaries (we don't have the cert/private key)
##   - malformed code signatures
##   - binaries with insufficient load-command slack
##
## Otherwise (thin Mach-O, unsigned or ad-hoc): mutate in place via
## the carved C codec, then re-sign ad-hoc with `codesign -s -` if
## the original was ad-hoc-signed.

import std/[
  options,
  strutils,
]

import ".."/[
  chalkjson,
  plugin_api,
  run_management,
  types,
  utils/exe,
  utils/fd_cache,
  utils/files,
  utils/macho,
]

type
  MachoCache = ref object of RootRef
    ## Per-artifact state held across scan → handleWrite calls.
    parsed:    ParsedMacho     ## Owned; freed when ChalkObj is dropped.
    sigKind:   ChalkMachoSigKind

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

var codesignPath = ""
proc getCodesignPath(): string =
  once:
    try:
      codesignPath = exe.findExePath("codesign").get("")
      if codesignPath == "":
        warn("No codesign command found in PATH")
    except:
      discard
  return codesignPath

proc adhocResign(path: string): bool =
  ## Restore an ad-hoc signature on a binary we just mutated.
  ## Returns true on success.  Emits a warn on failure.
  let output = runCmdGetEverything(
    getCodesignPath(),
    @[
      "--force",
      "--sign",
      "-",
      path
    ]
  )
  if output.exitCode != 0:
    warn("codesign --force --sign - failed for " & path & ": " &
         output.stderr.strip())
    return false

  return true

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

proc machoScan*(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  ## Sniff Mach-O magic, parse, classify; build a ChalkObj if we can
  ## handle this binary in-place.  Otherwise none → wrapper takes over.
  trace("machoScan: entering for " & path)

  # Cheap-first: peek 4 magic bytes via a stream and bail on
  # mismatch.  Most files chalk scans aren't Mach-O, and slurping a
  # multi-megabyte binary just to discard it is expensive.  Only
  # read the full file when magic actually matches.
  var bytes: string
  withFileStream(path, mode = fmRead, strict = false):
    if stream == nil:
      trace("machoScan: open failed for " & path)
      return none(ChalkObj)
    var magicBuffer: array[4, char]
    try:
      stream.peek(magicBuffer)
    except IOError, OSError, CatchableError:
      trace("machoScan: peek failed for " & path)
      return none(ChalkObj)
    if not isMachoMagic(magicBuffer):
      trace("machoScan: not Mach-O magic for " & path)
      return none(ChalkObj)
    try:
      bytes = stream.readAll()
    except IOError, OSError, CatchableError:
      trace("machoScan: readAll failed for " & path)
      return none(ChalkObj)

  let parsed = parseMacho(bytes)
  if parsed == nil:
    trace(path & ": Mach-O parse failed; deferring to wrapper")
    return none(ChalkObj)
  trace("machoScan: parsed ok for " & path)

  let sigKind = parsed.signatureKind()
  let existing = parsed.getChalkPayload()
  let hasChalkNote = existing != "" and existing.find(magicUTF8) != -1

  # For real-cert / malformed signatures we can't safely re-sign
  # after mutation, so we refuse handleWrite.  But if a chalk LC_NOTE
  # is already present, we can still EXTRACT it (LC_NOTE bytes are
  # plain bytes regardless of signing).  Claim the artifact in that
  # case so the wrapper codec doesn't waste effort scanning a binary
  # it wouldn't recognize as wrapped.
  if (sigKind == csRealCert or sigKind == csMalformed) and not hasChalkNote:
    case sigKind
    of csRealCert:
      trace(path & ": real-cert-signed Mach-O; deferring to wrapper")
    of csMalformed:
      warn(path & ": malformed code signature; deferring to wrapper")
    else:
      discard
    return none(ChalkObj)

  # Build a ChalkObj.  If a chalk note is already present, extract
  # its payload as the existing chalk mark.
  let cache = MachoCache(
    parsed:  parsed,
    sigKind: sigKind,
  )

  var dict: ChalkDict

  if hasChalkNote:
    dict   = extractOneChalkJson(existing, path)
  elif existing != "":
    warn(path & ": chalk LC_NOTE present but missing magic; " &
         "treating as unmarked")

  let chalk = newChalk(
    name         = path,
    fsRef        = path,
    codec        = self,
    resourceType = {ResourceFile},
    cache        = cache,
    extract      = dict,
  )

  return some(chalk)

# ---------------------------------------------------------------------------
# getUnchalkedHash
# ---------------------------------------------------------------------------

proc machoGetUnchalkedHash*(self: Plugin, chalk: ChalkObj):
                            Option[string] {.cdecl.} =
  ## Forward to the C-side canonicalize-then-SHA256 helper.  This
  ## hash is invariant under marking with payloads of any size: a
  ## marked binary and its unmarked equivalent yield the same hash
  ## (mirroring elf.nim's getUnchalkedHash semantics).
  if chalk.cachedUnchalkedHash != "":
    return some(chalk.cachedUnchalkedHash)

  let cache = MachoCache(chalk.cache)
  if cache == nil or cache.parsed == nil:
    return none(string)

  let hex = cache.parsed.unchalkedHash()
  if hex == "":
    error(chalk.name & ": unchalked hash computation failed")
    return none(string)

  chalk.cachedUnchalkedHash = hex
  return some(hex)

# ---------------------------------------------------------------------------
# handleWrite
# ---------------------------------------------------------------------------

proc machoHandleWrite*(self: Plugin, chalk: ChalkObj,
                       enc: Option[string]) {.cdecl.} =
  ## enc.isSome() → insert/replace chalk note with this payload.
  ## enc.isNone() → remove chalk note (unchalk).
  let cache = MachoCache(chalk.cache)
  if cache == nil or cache.parsed == nil:
    error(chalk.name & ": no parsed Mach-O state")
    chalk.opFailed = true
    return

  # Real-cert / malformed signatures: scan claimed the artifact for
  # extract, but we can't re-sign after mutation.  Refuse the write.
  if cache.sigKind == csRealCert:
    warn(chalk.name & ": cannot mutate Developer-ID-signed binary " &
         "(no cert / private key); use `codesign --remove-signature` " &
         "first or run chalk before signing")
    chalk.opFailed = true
    return
  if cache.sigKind == csMalformed:
    warn(chalk.name & ": malformed code signature; refusing to mutate")
    chalk.opFailed = true
    return
  if getCodesignPath() == "":
    warn(chalk.name & ": codesign not found in PATH — refusing to mutate")
    chalk.opFailed = true
    return

  # Compute the unchalked hash BEFORE mutating, so subsequent
  # mutation can't invalidate our view of the canonical bytes.
  discard chalk.callGetUnchalkedHash()

  # Strip any existing signature before mutating.  Apple's codesign
  # refuses to add a fresh signature past trailing payload bytes;
  # the only working layout is "no signature → mark → fresh sign."
  let stripSt = cache.parsed.stripSignature()
  if stripSt != cmOk:
    warn(chalk.name & ": signature strip failed (status " & $stripSt & ")")
    chalk.opFailed = true
    return

  let st =
    if enc.isSome() and enc.get().len > 0:
      cache.parsed.addChalkNote(enc.get())
    else:
      let r = cache.parsed.removeChalkNote()
      if r == cmNoChalkNote:
        cmOk  # nothing to remove is success.
      else:
        r

  if st != cmOk:
    case st
    of cmNoLcSlack:
      warn(chalk.name & ": insufficient load-command slack for " &
           "in-place LC_NOTE insert; deferring to wrapper would " &
           "require re-running chalk after this codec is disabled")
    of cmFat:
      warn(chalk.name & ": fat Mach-O not supported by native codec")
    else:
      warn(chalk.name & ": Mach-O write failed (status " & $st & ")")
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
    return

  # Sign the mutated binary.  We always re-sign unconditionally:
  # stripSignature dropped whatever sig was there, and an unsigned
  # arm64 binary won't run on macOS.  Re-applying ad-hoc keeps the
  # binary executable; a release pipeline can re-sign with
  # Developer ID downstream.
  if not adhocResign(chalk.fsRef):
    chalk.opFailed = true

# ---------------------------------------------------------------------------
# Metadata callbacks
# ---------------------------------------------------------------------------

proc machoGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                    ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("ARTIFACT_TYPE", artTypeMachO)

proc machoGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj,
                                  ins: bool): ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeMachO)

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc loadCodecMacho*() =
  newCodec(
    "macho",
    nativeObjPlatforms = @["macosx"],
    scan               = ScanCb(machoScan),
    handleWrite        = HandleWriteCb(machoHandleWrite),
    getUnchalkedHash   = UnchalkedHashCb(machoGetUnchalkedHash),
    ctArtCallback      = ChalkTimeArtifactCb(machoGetChalkTimeArtifactInfo),
    rtArtCallback      = RunTimeArtifactCb(machoGetRunTimeArtifactInfo),
  )
