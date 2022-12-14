import types
import config
import plugins
import resources
import io/tojson
import os

import strutils
import options
import strformat
import streams
import nativesockets
import std/tempfiles

proc doExtraction*(onBehalfOfInjection: bool) =
  # This function will extract SAMIs, leaving them in SAMI
  # objects inside the codecs.  That way, the inject command
  # can reuse this code.
  #
  # TODO: need to validate extracted SAMIs.
  # Also TODO, we will be adding output plugins very soon.
  var
    exclusions: seq[string]
    codecInfo: seq[Codec]
    ctx: FileStream
    f: File
    path: string
    filePath: string

  let
    artifactPath = getArtifactSearchPath()

  for (_, _, plugin) in getCodecsByPriority():
    let codec = cast[Codec](plugin)
    codec.doScan(artifactPath, exclusions, getRecursive())
    codecInfo.add(codec)

  try:
    if not onBehalfOfInjection and not getDryRun():
      filepath = fmtFullPath % [getOutputDir(), getOutputFile()]
      (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
      ctx = newFileStream(f)

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
            keyJson = strKeyToJson(key)
            valJson = embstore.foundToJson()

          if not onBehalfOfInjection and not getDryRun():
            embededJson = embededJson & kvPairJFmt.fmt()
            comma = comfyItemSep

        embededJson = jsonArrFmt % [embededJson]

        if not onBehalfOfInjection and not getDryRun():
          let outstr = logTemplate % [sami.fullpath, getHostName(),
                                      primaryJson, embededJson]
          ctx.writeLine(outstr)
  except:
    # TODO: do better here.
    # echo getStackTrace()
    # raise
    warn(getCurrentExceptionMsg() & " (likely a bad SAMI embed; ignored)")
  finally:
    if ctx != nil:
      ctx.close()
      try:
        moveFile(path, filepath)
      except:
        removeFile(path)
        raise

