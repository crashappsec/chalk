## Entry point for chalk extraction, used both by the 'extract'
## command and by most other commands that first scan and see what's
## already there.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strformat, strutils, os, options, nativesockets, json, glob
import nimSHA2, con4m, nimutils, types, config, plugins, io/[tojson, tobinary]

const
  # This is the logging template for JSON output.
  logFmt       = """{
  "ARTIFACT_PATH"     : $#,
  "CHALK"             : $#,
  "EMBEDDED_CHALK"    : $#,
  "VALIDATION_PASSED" : $#
}"""
  verifyTypeStr     = "f(string, string, {string: string}) -> bool"
let verifyType      = verifyTypeStr.toCon4mType()

proc validateMetadata(codec: Codec, obj: ChalkObj): bool =
  result = true

  var
    rawHash      = codec.getArtifactHash(obj)
    ulidHiBytes  = rawHash[^10 .. ^9]
    ulidLowBytes = rawHash[^8 .. ^1]
    ulidHiInt    = (cast[ptr uint16](addr ulidHiBytes[0]))[]
    ulidLowInt   = (cast[ptr uint64](addr ulidLowBytes[0]))[]
    now          = 0'u64
    chalkId      = encodeUlid(now, ulidHiInt, ulidLowInt)

  if "CHALK_ID" notin obj.extract:
    error(fmt"{obj.fullPath}: required field 'CHALK_ID' is missing.")
    result = false
  elif len(unpack[string](obj.extract["CHALK_ID"])) != 26:
    error(fmt"{obj.fullPath}: 'CHALK_ID' is invalid length (expected 26 bytes)")
    result = false
  else:
    let extractedId = (unpack[string](obj.extract["CHALK_ID"]))[^15 .. ^1]
    if chalkId[^15 .. ^1] != extractedId:
      error(fmt"{obj.fullPath}: Calculated CHALK_ID doesn't match extracted " &
            fmt"ID '{chalkId[^15 .. ^1]}' vs '{extractedId}'")
      result = false

  if "METADATA_ID" notin obj.extract:
    error(fmt"{obj.fullPath}: Required field METADATA_ID is missing")
    if "METADATA_HASH" notin obj.extract:
      error(fmt"{obj.fullPath}: No information found for METAID validation")
      return false
  var
    toHash = obj.extract.foundToBinary()
    shaCtx = initSHA[SHA256]()

  shaCtx.update(toHash)

  var mdRawHash = $(shaCtx.final())
  ulidHiBytes   = mdRawHash[^10 .. ^9]
  ulidLowBytes  = mdRawHash[^8 .. ^1]
  ulidHiInt     = (cast[ptr uint16](addr ulidHiBytes[0]))[]
  ulidLowInt    = (cast[ptr uint64](addr ulidLowBytes[0]))[]
  chalkId       = encodeUlid(now, ulidHiInt, ulidLowInt)

  if "METADATA_HASH" in obj.extract:
    let
      ourHash   = mdRawHash.toHex().toLowerAscii()
      theirHash = unpack[string](obj.extract["METADATA_HASH"]).toLowerAscii()
    if ourHash != theirHash:
      error(fmt"{obj.fullPath}: METADATA_HASH field does not match " &
               "calculated value")
      result = false
    elif "METADATA_ID" in obj.extract:
      # This check was redundant, they were required to appear together.
      # just being a little cautious.
      let
        mdId          = unpack[string](obj.extract["METADATA_ID"])
        mdidValidator = mdId[^15 .. ^1]
      if chalkId[^15 .. ^1] != mdidValidator:
        error(fmt"{obj.fullPath}: METADATA_ID field does not match " &
                 "calculated value")
        result = false
      if "SIGNATURE" in obj.extract:
        # This matches code in metsys.nim that calls sign()
        let
          artHash  = rawHash.toHex().toLowerAscii()
          mdid     = (unpack[string](obj.extract["METADATA_ID"]))
          toVerify = pack(artHash & "\n" & ourHash & "\n" & mdid & "\n")
          args     = @[toVerify,
                       obj.extract["SIGNATURE"],
                       obj.extract["SIGN_PARAMS"]]
          optValid = ctxChalkConf.sCall("verify", args, verifyType)

        # If verify() isn't provided, the caller doesn't care about
        # signature checking.
        if optValid.isSome():
          result = unpack[bool](optValid.get())
          if not result:
            error(fmt"{obj.fullPath}: signature verification failed.")
          else:
            info(fmt"{obj.fullPath}: signature successfully verified.")
        else:
          once:
            warn(fmt"{obj.fullPath}: no signature validation routine provided.")

proc doExtraction*(): Option[string] =
  # This function will extract chalk, leaving them in chalk objects
  # inside the codecs.  it does NOT do any output, but it does build a
  # single JSON string that *could* be output.
  #
  # We do not process the actual binary that is running, if it
  # happens to be in the search path.  It's a special command to do a
  # self-insertion, partially to avoid accidents, and partially
  # because we overload the capability for loading / unloading the
  # admin's config file.
  var
    exclusions:  seq[string] = if getSelfInjecting(): @[]
                               else: @[resolvePath(getAppFileName())]
    codecInfo:   seq[Codec]  = getCodecsByPriority()
    chalksToRet: seq[string] = @[]
    unmarked:    seq[string] # Unmarked artifacts.
    skips:       seq[Glob]   = @[]
    artifactPath             = chalkConfig.getArtifactSearchPath()
    recursive                = chalkConfig.getRecursive()
    numExtractions           = 0

  # We want extraction and deletion to not miss stuff, so don't use patterns.
  if getCommandName() == "insert":
    for item in chalkConfig.getIgnorePatterns():
      skips.add(glob("**/" & item))
  for codec in codecInfo:
    var keepScanning = true
    trace(fmt"Asking codec '{codec.name}' to scan for chalk.")
    # A codec can return 'false' to short circuit all other plugins.
    # This is used, for instance, with containers.
    keepScanning = codec.extractAll(artifactPath, exclusions, skips, recursive)
    for obj in codec.chalks:
      if not obj.isMarked():
        let err = obj.fullpath & ": Currently unchalked"
        if obj.fullpath.mustIgnore(skips): trace(err): else: info(err)
        unmarked.add(obj.fullpath)
        continue
      var
        embededJson = ""
        primaryJson = obj.foundToJson()
        valid       = $(validateMetadata(codec, obj))
        absPath     = escapeJson(resolvePath(obj.fullpath))

      for i, artifact in obj.embeds:
        if i != 0: embededJson &= ", "
        embededJson &= strValToJson(artifact.fullPath) & " : "
        embededJson &= artifact.foundToJson()

      embededJson     = "[$#]" % [embededJson]
      numExtractions += 1

      chalksToRet.add(logFmt % [absPath, primaryJson, embededJson, valid])
      info(obj.fullpath & ": chalk extracted")
      if getCommandName() == "extract": obj.yieldFileStream()

      # Short circuit only if codec actually chalked something.
    if not keepScanning and len(codec.chalks) > 0: break

  if numExtractions == 0: return none(string)
  var toOut = "{ \"action\" : " & escapeJson(getCommandName()) & ", "
  toOut &= "\"extractions\" : [ " & chalksToRet.join(", ") & " ] "

  if chalkConfig.getPublishUnmarked():
    toOut &= ", \"unmarked\" : " & $( %* unmarked)

  result = some(toOut & "}")

  info(fmt"Completed {numExtractions} extractions.")

var selfChalk: Option[ChalkObj] = none(ChalkObj)
var selfID:    Option[string] = none(string)

proc getSelfExtraction*(): Option[ChalkObj] =
  # If we call twice and we're on a platform where we don't
  # have a codec for this type of executable, avoid dupe errors.
  once:
    var
      myPath = @[resolvePath(getAppFileName())]
      exclusions: seq[string] = @[]

    trace(fmt"Checking chalk binary {myPath[0]} for embedded config")

    for codec in getCodecsByPriority():
      if hostOS notin codec.getNativeObjPlatforms(): continue
      discard codec.extractAll(myPath, exclusions, @[], false)
      if len(codec.chalks) == 0:
        info("No embedded self-chalking found.")
        return none(ChalkObj)
      selfChalk = some(codec.chalks[0])
      codec.chalks = @[]
      if "CHALK_ID" notin selfChalk.get().extract:
        error("Self-chalk is invalid.")
        return none(ChalkObj)
      selfId = some(unpack[string](selfChalk.get().extract["CHALK_ID"]))
      return selfChalk

    warn(fmt"We have no codec for this platform's native executable type")
    setNoSelfInjection()

  return selfChalk

proc getSelfID*(): Option[string] =
  return selfID
