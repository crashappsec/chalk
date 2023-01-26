import tables, strformat, strutils, os, options, nativesockets, json, glob
import nimSHA2, nimutils, config, plugins, io/[tojson, tobinary]

const
  # This is the logging template for JSON output.
  logTemplate       = """{
  "ARTIFACT_PATH": $#,
  "SAMI" : $#,
  "EMBEDDED_SAMIS" : $#,
  "VALIDATION_PASSED" : $#
}"""
  fmtInfoNoExtract  = "{sami.fullpath}: No SAMI found for extraction"
  fmtInfoYesExtract = "{sami.fullpath}: SAMI extracted"
  fmtInfoNoPrimary  = "{sami.fullpath}: couldn't find a primary SAMI insertion"
  comfyItemSep      = ", "
  jsonArrFmt        = "[ $# ]"

proc validateMetadata(codec: Codec, sami: SamiObj, fields: SamiDict): bool =
  result = true

  var
    rawHash      = codec.getArtifactHash(sami)
    ulidHiBytes  = rawHash[^10 .. ^9]
    ulidLowBytes = rawHash[^8 .. ^1]
    ulidHiInt    = (cast[ptr uint16](addr ulidHiBytes[0]))[]
    ulidLowInt   = (cast[ptr uint64](addr ulidLowBytes[0]))[]
    now          = 0'u64
    samiId       = encodeUlid(now, ulidHiInt, ulidLowInt)

  if "SAMI_ID" notin fields:
    error(fmt"{sami.fullPath}: required SAMI_ID field is missing.")
    result = false

  elif len(unpack[string](fields["SAMI_ID"])) != 26:
    error(fmt"{sami.fullPath}: SAMI_ID is invalid length (expected 26 bytes)")
    result = false

  elif samiId[^15 .. ^1] != (unpack[string](fields["SAMI_ID"]))[^15 .. ^1]:
    error(fmt"{sami.fullPath}: Calculated SAMI_ID doesn't match extracted ID " &
          fmt"'{samiId[^15 .. ^1]}' vs " &
          (unpack[string](fields["SAMI_ID"]))[^15 .. ^1])
    result = false

  # TODO: else: validate metadata hash... use foundToBinary
  if "METADATA_ID" notin fields:
    error(fmt"{sami.fullPath}: Required field METADATA_ID is missing")
    if "METADATA_HASH" notin fields:
      error(fmt"{sami.fullPath}: No information found for METAID validation")
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
  samiId       = encodeUlid(now, ulidHiInt, ulidLowInt)

  if "METADATA_HASH" in fields:
    let
      ourHash   = rawHash.toHex.toLowerAscii()
      theirHash = unpack[string](fields["METADATA_HASH"]).toLowerAscii()
    if ourHash != theirHash:
      error(fmt"{sami.fullPath}: METADATA_HASH field does not match " &
               "calculated value")
      result = false
  if "METADATA_ID" in fields:
    if samiId[^15 .. ^1] != (unpack[string](fields["METADATA_ID"]))[^15 .. ^1]:
      error(fmt"{sami.fullPath}: METADATA_HASH field does not match " &
               "calculated value")
      result = false

proc doExtraction*(): Option[string] =
  # This function will extract SAMIs, leaving them in SAMI objects
  # inside the codecs.  it does NOT do any output, but it does build a
  # single JSON string that *could* be output.
  #
  # TODO: need to validate extracted SAMIs.
  #
  # We do not process the actual sami binary that is running, if it
  # happens to be in the search path.  It's a special command to do a
  # self-insertion, partially to avoid accidents, and partially
  # because we overload the capability for loading / unloading the
  # admin's config file.
  var
    exclusions:  seq[string] = if getSelfInjecting(): @[]
                               else: @[resolvePath(getAppFileName())]
    codecInfo:   seq[Codec]
    samisToRet:  seq[string] = @[]
    unmarked:    seq[string]       # Unmarked artifacts.
    ignoreGlobs: seq[Glob]   = @[]
    artifactPath             = getArtifactSearchPath()
    ignorePatternsAsStr      = getIgnorePatterns()
    numExtractions           = 0

  for item in ignorePatternsAsStr:
    ignoreGlobs.add(glob("**/" & item))

  for plugin in getCodecsByPriority():
    let codec = cast[Codec](plugin)
    trace(fmt"Asking codec '{plugin.name}' to scan for SAMIs.")
    if getCommandName() == "insert":
      if not codec.doScan(artifactPath,
                          exclusions,
                          ignoreGlobs,
                          getRecursive()):
        codecInfo.add(codec)
        break
    else:
      if not codec.doScan(artifactPath, exclusions, @[], getRecursive()):
        codecInfo.add(codec)
        break
    codecInfo.add(codec)

  trace("Beginning extraction attempts for any found SAMIs")

  try:
    for codec in codecInfo:

      for sami in codec.samis:
        var comma, primaryJson, embededJson: string
        var isValid: bool

        if sami.samiIsEmpty():
          # mustIgnore is in plugins.nim
          if mustIgnore(sami.fullpath, ignoreGlobs):
            trace(fmtInfoNoExtract.fmt())
          else:
            info(fmtInfoNoExtract.fmt())
          unmarked.add(sami.fullpath)

          continue
        if sami.samiHasExisting():
          let
            p = sami.primary
            s = p.samiFields.get()
          primaryJson = s.foundToJson()
          isValid = validateMetadata(codec, sami, s)
          info(fmtInfoYesExtract.fmt())
        else:
          info(fmtInfoNoPrimary.fmt())

        for (key, pt) in sami.embeds:
          let
            embstore = pt.samiFields.get()
            keyJson = strValToJson(key)
            valJson = embstore.foundToJson()

          embededJson = fmt"{embededJson}{comma}{keyJson} : {valJson}"
          comma = comfyItemSep

        embededJson = jsonArrFmt % [embededJson]

        numExtractions += 1

        let absPath = resolvePath(sami.fullpath)
        samisToRet.add(logTemplate %
                 [escapeJson(absPath), primaryJson, embededJson, $isValid])
  except:
    publish("debug", getCurrentException().getStackTrace())
    error(getCurrentExceptionMsg() & " (likely a bad SAMI embed)")
  finally:
    if numExtractions == 0:
      return none(string)
    var toOut = "{ \"action\" : " & escapeJson(getCommandName()) & ", "
    toOut &= "\"extractions\" : [ " & samisToRet.join(", ") & " ] "

    if getPublishUnmarked():
      toOut &= ", \"unmarked\" : " & $( %* unmarked)

    toOut &= "}"
    result = some(toOut)

    info(fmt"Completed {numExtractions} extractions.")

var selfSamiObj: Option[SamiObj] = none(SamiObj)
var selfSami:    Option[SamiDict] = none(SamiDict)
var selfID:      Option[string] = none(string)

proc getSelfSamiObj*(): Option[SamiObj] =
  # If we call twice and we're on a platform where we don't
  # have a codec for this type of executable, avoid dupe errors.
  once:
    var
      myPath = @[resolvePath(getAppFileName())]
      exclusions: seq[string] = @[]

    trace(fmt"Checking sami binary {myPath[0]} for embedded config")

    for plugin in getCodecsByPriority():
      let codec = cast[Codec](plugin)
      discard codec.doScan(myPath, exclusions, @[], false)
      if len(codec.samis) == 0: continue
      selfSamiObj = some(codec.samis[0])
      codec.samis = @[]
      return selfSamiObj

    warn(fmt"We have no codec for this platform's native executable type")
    setNoSelfInjection()

  return selfSamiObj

proc getSelfExtraction*(): Option[SamiDict] =
  once:
    let samiObjOpt = getSelfSamiObj()
    if not samiObjOpt.isSome():
      trace(fmt"Binary does not have an embedded configuration.")
      return none(SamiDict)

    let
      obj = samiObjOpt.get()
      pt = obj.primary

    # Keep this out of the let block; it's a module level variable!
    selfSami = pt.samiFields

    if obj.samiIsEmpty() or not obj.samiHasExisting():
      trace(fmt"No embedded self-SAMI found.")
      return none(SamiDict)
    else:
      trace(fmt"Found existing self-SAMI.")
      let sami = selfSami.get()
      # Should always be true, but just in case.
      if sami.contains("SAMI_ID"):
        selfID = some(unpack[string](sami["SAMI_ID"]))

  return selfSami

proc getSelfID*(): Option[string] =
  return selfID
