## Entry point for chalk extraction, used both by the 'extract'
## command and by most other commands that first scan and see what's
## already there.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strformat, strutils, os, options, nativesockets, json, glob
import nimSHA2, nimutils, types, config, plugins, io/[tojson, tobinary]

const
  # This is the logging template for JSON output.
  logTemplate       = """{
  "ARTIFACT_PATH": $#,
  "CHALK" : $#,
  "EMBEDDED_CHALK" : $#,
  "VALIDATION_PASSED" : $#
}"""
  fmtInfoNoExtract  = "{obj.fullpath}: No chalk found for extraction"
  fmtInfoYesExtract = "{obj.fullpath}: chalk extracted"
  fmtInfoNoPrimary  = "{obj.fullpath}: couldn't find a primary chalk insertion"
  comfyItemSep      = ", "
  jsonArrFmt        = "[ $# ]"

proc validateMetadata(codec: Codec, obj: ChalkObj, fields: ChalkDict): bool =
  result = true

  var
    rawHash      = codec.getArtifactHash(obj)
    ulidHiBytes  = rawHash[^10 .. ^9]
    ulidLowBytes = rawHash[^8 .. ^1]
    ulidHiInt    = (cast[ptr uint16](addr ulidHiBytes[0]))[]
    ulidLowInt   = (cast[ptr uint64](addr ulidLowBytes[0]))[]
    now          = 0'u64
    chalkId      = encodeUlid(now, ulidHiInt, ulidLowInt)

  if "CHALK_ID" notin fields:
    error(fmt"{obj.fullPath}: required field 'CHALK_ID' is missing.")
    result = false

  elif len(unpack[string](fields["CHALK_ID"])) != 26:
    error(fmt"{obj.fullPath}: 'CHALK_ID' is invalid length (expected 26 bytes)")
    result = false

  elif chalkId[^15 .. ^1] != (unpack[string](fields["CHALK_ID"]))[^15 .. ^1]:
    error(fmt"{obj.fullPath}: Calculated CHALK_ID doesn't match extracted ID " &
          fmt"'{chalkId[^15 .. ^1]}' vs " &
          (unpack[string](fields["CHALK_ID"]))[^15 .. ^1])
    result = false

  # TODO: else: validate metadata hash... use foundToBinary
  if "METADATA_ID" notin fields:
    error(fmt"{obj.fullPath}: Required field METADATA_ID is missing")
    if "METADATA_HASH" notin fields:
      error(fmt"{obj.fullPath}: No information found for METAID validation")
      return false
  var
    toHash = foundToBinary(fields)
    shaCtx = initSHA[SHA256]()

  shaCtx.update(toHash)

  rawHash      = $(shaCtx.final())
  ulidHiBytes  = rawHash[^10 .. ^9]
  ulidLowBytes = rawHash[^8 .. ^1]
  ulidHiInt    = (cast[ptr uint16](addr ulidHiBytes[0]))[]
  ulidLowInt   = (cast[ptr uint64](addr ulidLowBytes[0]))[]
  chalkId      = encodeUlid(now, ulidHiInt, ulidLowInt)

  if "METADATA_HASH" in fields:
    let
      ourHash   = rawHash.toHex.toLowerAscii()
      theirHash = unpack[string](fields["METADATA_HASH"]).toLowerAscii()
    if ourHash != theirHash:
      error(fmt"{obj.fullPath}: METADATA_HASH field does not match " &
               "calculated value")
      result = false
  if "METADATA_ID" in fields:
    if chalkId[^15 .. ^1] != (unpack[string](fields["METADATA_ID"]))[^15 .. ^1]:
      error(fmt"{obj.fullPath}: METADATA_HASH field does not match " &
               "calculated value")
      result = false

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
    codecInfo:   seq[Codec]
    chalksToRet: seq[string] = @[]
    unmarked:    seq[string]       # Unmarked artifacts.
    ignoreGlobs: seq[Glob]   = @[]
    artifactPath             = chalkConfig.getArtifactSearchPath()
    ignorePatternsAsStr      = chalkConfig.getIgnorePatterns()
    recursive                = chalkConfig.getRecursive()
    numExtractions           = 0

  for item in ignorePatternsAsStr:
    ignoreGlobs.add(glob("**/" & item))

  for plugin in getCodecsByPriority():
    let codec = cast[Codec](plugin)
    trace(fmt"Asking codec '{plugin.name}' to scan for chalk.")
    if getCommandName() == "insert":
      if not codec.doScan(artifactPath, exclusions, ignoreGlobs, recursive):
        codecInfo.add(codec)
        break
    else:
      if not codec.doScan(artifactPath, exclusions, @[], recursive):
        codecInfo.add(codec)
        break
    codecInfo.add(codec)

  trace("Beginning extraction attempts for any found chalk")

  try:
    for codec in codecInfo:

      for obj in codec.chalks:
        var comma, primaryJson, embededJson: string
        var isValid: bool

        if obj.chalkIsEmpty():
          # mustIgnore is in plugins.nim
          if mustIgnore(obj.fullpath, ignoreGlobs):
            trace(fmtInfoNoExtract.fmt())
          else:
            info(fmtInfoNoExtract.fmt())
          unmarked.add(obj.fullpath)

          continue
        if obj.chalkHasExisting():
          let
            p = obj.primary
            s = p.chalkFields.get()
          primaryJson = s.foundToJson()
          isValid = validateMetadata(codec, obj, s)
          info(fmtInfoYesExtract.fmt())
        else:
          info(fmtInfoNoPrimary.fmt())

        for (key, pt) in obj.embeds:
          let
            embstore = pt.chalkFields.get()
            keyJson = strValToJson(key)
            valJson = embstore.foundToJson()

          embededJson = fmt"{embededJson}{comma}{keyJson} : {valJson}"
          comma = comfyItemSep

        embededJson = jsonArrFmt % [embededJson]

        numExtractions += 1

        let absPath = resolvePath(obj.fullpath)
        chalksToRet.add(logTemplate %
                 [escapeJson(absPath), primaryJson, embededJson, $isValid])
  except:
    publish("debug", getCurrentException().getStackTrace())
    error(getCurrentExceptionMsg() & " (likely a bad chalk embed)")
  finally:
    if numExtractions == 0:
      return none(string)
    var toOut = "{ \"action\" : " & escapeJson(getCommandName()) & ", "
    toOut &= "\"extractions\" : [ " & chalksToRet.join(", ") & " ] "

    if chalkConfig.getPublishUnmarked():
      toOut &= ", \"unmarked\" : " & $( %* unmarked)

    toOut &= "}"
    result = some(toOut)

    info(fmt"Completed {numExtractions} extractions.")

var selfChalkObj: Option[ChalkObj] = none(ChalkObj)
var selfChalk:    Option[ChalkDict] = none(ChalkDict)
var selfID:       Option[string] = none(string)

proc getSelfChalkObj*(): Option[ChalkObj] =
  # If we call twice and we're on a platform where we don't
  # have a codec for this type of executable, avoid dupe errors.
  once:
    var
      myPath = @[resolvePath(getAppFileName())]
      exclusions: seq[string] = @[]

    trace(fmt"Checking chalk binary {myPath[0]} for embedded config")

    for plugin in getCodecsByPriority():
      let codec = cast[Codec](plugin)
      discard codec.doScan(myPath, exclusions, @[], false)
      if len(codec.chalks) == 0: continue
      selfChalkObj = some(codec.chalks[0])
      codec.chalks = @[]
      return selfChalkObj

    warn(fmt"We have no codec for this platform's native executable type")
    setNoSelfInjection()

  return selfChalkObj

proc getSelfExtraction*(): Option[ChalkDict] =
  once:
    let chalkObjOpt = getSelfChalkObj()
    if not chalkObjOpt.isSome():
      trace(fmt"Binary does not have an embedded configuration.")
      return none(ChalkDict)

    let
      obj = chalkObjOpt.get()
      pt = obj.primary

    # Keep this out of the let block; it's a module level variable!
    selfChalk = pt.chalkFields

    if obj.chalkIsEmpty() or not obj.chalkHasExisting():
      trace(fmt"No embedded self-chalking found.")
      return none(ChalkDict)
    else:
      trace(fmt"Found existing self-chalk.")
      let obj = selfChalk.get()
      # Should always be true, but just in case.
      if obj.contains("CHALK_ID"):
        selfID = some(unpack[string](obj["CHALK_ID"]))

  return selfChalk

proc getSelfID*(): Option[string] =
  return selfID
