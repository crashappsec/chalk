import tables, strformat, strutils, os, options, nativesockets
import nimutils, config, plugins, io/tojson

const
  # This is the logging template for JSON output.
  logTemplate       = """{ 
  "SAMI" : $#,
  "EMBEDDED_SAMIS" : $#
}"""
  fmtInfoNoExtract  = "{sami.fullpath}: No SAMI found for extraction"
  fmtInfoYesExtract = "{sami.fullpath}: SAMI extracted"
  fmtInfoNoPrimary  = "{sami.fullpath}: couldn't find a primary SAMI insertion"
  comfyItemSep      = ", "
  jsonArrFmt        = "[ $# ]"


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
    exclusions: seq[string] = if getSelfInjecting(): @[]
                              else: @[resolvePath(getAppFileName())]
    codecInfo: seq[Codec]
    numExtractions = 0
    samisToRet: seq[string] = @[]

  var artifactPath = getArtifactSearchPath()

  for (_, name, plugin) in getCodecsByPriority():
    let codec = cast[Codec](plugin)
    trace(fmt"Asking codec '{name}' to scan for SAMIs.")
    codec.doScan(artifactPath, exclusions, getRecursive())
    codecInfo.add(codec)

  trace("Beginning extraction attempts for any found SAMIs")

  try:
    for codec in codecInfo:
      for sami in codec.samis:
        var comma, primaryJson, embededJson: string

        if sami.samiIsEmpty():
          info(fmtInfoNoExtract.fmt())
          continue
        if sami.samiHasExisting():
          let
            p = sami.primary
            s = p.samiFields.get()
          primaryJson = s.foundToJson()
          dryRun(fmtInfoYesExtract.fmt())
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

        let absPath = absolutePath(sami.fullpath)
        samisToRet.add(logTemplate % [primaryJson, embededJson])
  except:
    # TODO: do better here.
    echo getCurrentException().getStackTrace()
    error(getCurrentExceptionMsg() & " (likely a bad SAMI embed)")
  finally:
    if numExtractions == 0:
      return none(string)
    result = some("[" & samisToRet.join(", ") & "]")
    info(fmt"Completed {numExtractions} extractions.")

var selfSamiObj: Option[SamiObj] = none(SamiObj)
var selfSami: Option[SamiDict] = none(SamiDict)

proc getSelfSamiObj*(): Option[SamiObj] =
  # If we somehow call this twice, no need to re-compute.
  if selfSamiObj.isSome():
    return selfSamiObj
  
  var
    myPath = @[resolvePath(getAppFileName())]
    exclusions: seq[string] = @[]
    
  trace(fmt"Checking sami binary {myPath[0]} for embedded config")
  
  for (_, name, plugin) in getCodecsByPriority():
    let codec = cast[Codec](plugin)
    codec.doScan(myPath, exclusions, false)
    if len(codec.samis) == 0: continue
    selfSamiObj = some(codec.samis[0])
    codec.samis = @[]
    return selfSamiObj

  warn(fmt"We have no codec for this platform's native executable type")
  return none(SamiObj)

var selfID: Option[uint] = none(uint)

proc getSelfExtraction*(): Option[SamiDict] =
  # If we somehow call this twice, no need to re-compute.
  if selfSami.isSome():
    return selfSami
  
  let samiObjOpt = getSelfSamiObj()
  if not samiObjOpt.isSome(): return none(SamiDict)

  let
    obj = samiObjOpt.get()
    pt = obj.primary
    selfSami = pt.samiFields
    
  if obj.samiIsEmpty() or not obj.samiHasExisting():
    trace(fmt"No embedded self-SAMI found.")
    return none(SamiDict)
  else:
    trace(fmt"Found existing self-SAMI.")
    let sami = selfSami.get()
    # Should always be true, but just in case.
    if sami.contains("SAMI_ID"):
      selfID = some(unpack[uint](sami["SAMI_ID"]))
      
  return selfSami

proc getSelfID*(): Option[uint] =
  return selfID
