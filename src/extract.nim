import config
import plugins
import resources
import io/tojson
import output

import os
import strutils
import options
import strformat
import streams
import nativesockets

proc doExtraction*(onBehalfOfInjection: bool) =
  # This function will extract SAMIs, leaving them in SAMI
  # objects inside the codecs.  That way, the inject command
  # can reuse this code.
  #
  # TODO: need to validate extracted SAMIs.
  # 
  # We do not process the actual sami binary that is running, if it
  # happens to be in the search path.  It's a special command to do a
  # self-insertion, partially to avoid accidents, and partially
  # because we overload the capability for loading / unloading the
  # admin's config file.
  var
    exclusions: seq[string] = @[joinPath(getAppDir(), getAppFileName())]
    codecInfo: seq[Codec]
    ctx: FileStream
    path: string
    filePath: string
    numExtractions = 0
    samisToOut: seq[string] = @[]

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
          inform(fmtInfoNoExtract.fmt())
          continue
        if sami.samiHasExisting():
          let
            p = sami.primary
            s = p.samiFields.get()
          primaryJson = s.foundToJson()
          forceInform(fmtInfoYesExtract.fmt())
        else:
          inform(fmtInfoNoPrimary.fmt())

        for (key, pt) in sami.embeds:
          let
            embstore = pt.samiFields.get()
            keyJson = strValToJson(key)
            valJson = embstore.foundToJson()

          if not onBehalfOfInjection and not getDryRun():
            embededJson = embededJson & kvPairJFmt.fmt()
            comma = comfyItemSep

        embededJson = jsonArrFmt % [embededJson]

        numExtractions += 1

        let absPath = absolutePath(sami.fullpath)
        samisToOut.add(logTemplate % [absPath, getHostName(),
                                      primaryJson, embededJson])

    let toOut = "[" & samisToOut.join(", ") & "]"
    handleOutput(toOut, if onBehalfOfInjection: OutCtxInjectPrev
                        else: OutCtxExtract)
  except:
    # TODO: do better here.
    # echo getStackTrace()
    # raise
    warn(getCurrentExceptionMsg() &
         " (likely a bad SAMI embed; ignored)")
  finally:
    trace(fmt"Completed {numExtractions} extractions.")
    if ctx != nil:
      ctx.close()
      try:
        moveFile(path, filepath)
      except:
        removeFile(path)
        raise

var selfSami: Option[SamiDict] = none(SamiDict)

proc getSelfExtraction*(): Option[SamiDict] =
  # If we somehow call this twice, no need to re-compute.
  if selfSami.isSome():
    return selfSami
  
  var
    myPath = @[joinPath(getAppDir(), getAppFileName())]
    exclusions: seq[string] = @[]
    
  trace(fmt"Checking sami binary @{myPath} for embedded config")
  
  for (_, name, plugin) in getCodecsByPriority():
    let codec = cast[Codec](plugin)
    codec.doScan(myPath, exclusions, false)
    if len(codec.samis) == 0: continue
    let
      obj = codec.samis[0]
      pt = obj.primary
    codec.samis = @[]
    selfSami = pt.samiFields
    if obj.samiIsEmpty() or not obj.samiHasExisting():
      trace(fmt"No embedded self-SAMI found.")
    else:
      trace(fmt"Found existing self-SAMI.")
    return selfSami
      
  warn(fmt"We have no codec for this platform's native executable type")
  return none(SamiDict)

