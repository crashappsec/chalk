## This is the implementation of the 'insert' / 'inject' command, and
## basically orchestrates collecting data from plugins and calling out
## to do actual outputting.
##
## Once logic gets into the realm of a single plugin / codec, the
## implementation moves mainly to plugin.c (the plugins themselves
## generally are never going to be very big).
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import options, tables, streams, strutils, strformat, os, std/tempfiles
import nimutils, types, config, plugins, extract, io/tojson, builtins

const
  codecOnlyKeys = ["ARTIFACT_PATH", "HASH", "HASH_FILES",
                   "COMPONENT_HASHES", "CHALK_ID"]
  optionalCodecKeys = ["COMPONENT_HASHES"]


var systeMetsys: array[2, Plugin]

proc getSystemPlugins(): array[2, Plugin] {.inline.} =
  once:
    systeMetsys = [getPluginByName("system"), getPluginByName("metsys")]

  return systeMetsys

proc acquireStreamIfUsed(codec: Codec, infoObj: ChalkObj) =
  if codec.configInfo.getUsesFstream():
    discard infoObj.acquireFileStream()

proc isValidChalk(obj: ChalkObj): bool =
  result = true
  for key in getRequiredKeys():
    if key notin obj.newFields:
      error(fmt"{obj.fullPath} is missing key: {key}")
      result = false

proc doOneInjection(obj: ChalkObj, codec: Codec): string =
  result = obj.createdToJson(false)

  let toInject =  if getOutputPointers():
                    obj.createdToJson(true):
                  else:
                    result
  if chalkConfig.getDryRun():
    info("{obj.fullPath}: would inject; publishing to 'dry-run' instead")
    publish("dry-run", toInject)
    return

  if SkipWrite in obj.flags or not codec.configInfo.getUsesFstream():
    codec.handleWrite(nil, "", some(toInject), "")
    return

  let
    stream = obj.stream
    point  = obj.primary

  stream.setPosition(0)

  let pre = stream.readStr(point.startOffset)

  if point.endOffset > point.startOffset:
    stream.setPosition(point.endOffset)

  let post = stream.readAll()

  obj.closeFileStream()
  var
    f:    File
    path: string
    ctx:  FileStream

  try:
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
    ctx       = newFileStream(f)

    codec.handleWrite(ctx, pre, some(toInject), post)
    if point.present:
      info(fmt"{obj.fullPath}: artifact metadata replaced.")
    else:
      info(fmt"{obj.fullPath}: new artifact metadata added.")
  except:
    error(fmt"{obj.fullPath}: insertion failed.")
    removeFile(path)
  finally:
    if ctx != nil:
      ctx.close()
      try:
        let newPath = if getSelfInjecting(): obj.fullPath & ".new"
                      else: obj.fullPath
        moveFile(path, newPath)
        if getSelfInjecting():
          info(fmt"Wrote new binary with loading conf to {newpath}")
      except:
        removeFile(path)
        error(fmt"{obj.fullPath}: Could not write (no permission)")

proc doInjection*() =
  var
    objsForPublish: seq[string] = @[]
  let
    codecs      = getCodecsByPriority()
    everyKey    = getOrderedKeys()
    inDryRun    = chalkConfig.getDryRun()
    extractions = doExtraction()
    pluginInfo  = getPluginsByPriority()

  # Anything we've extracted is for an artifact where we are about to
  # inject over it.  Report these to the "replacing" output stream.
  if extractions.isSome():
    publish("replacing", extractions.get())

  for plugin in codecs:
    let
      name            = plugin.name
      codec           = Codec(plugin)
      extracts        = codec.getChalks()
      codecIgnores    = codec.configInfo.getIgnore()
      xtraKeys        = codec.configInfo.getKeys()
      streamAvailable = codec.configInfo.getUsesFstream()

    for infoObj in extracts:
      pushTargetChalkForErrorMsgs(infoObj)
      let
        keyInfo = codec.getArtifactInfo(infoObj)
        path    = infoObj.fullPath


      infoObj.newFields = ChalkDict()
      codec.acquireStreamIfUsed(infoObj)

      trace(fmt"{path}: Codec '{name}' beginning metadata collection.")

      for key in codecOnlyKeys:
        if key notin keyInfo and key notin optionalCodecKeys:
          error(fmt"{name}: Did not provide required key {key} for " &
                fmt"artifact at: {infoObj.full_path}")
          continue
        if key in keyInfo:
          infoObj.newFields[key] = keyInfo[key]

      for key in xtraKeys:
        if key in codecIgnores or key notin keyInfo: continue
        infoObj.newFields[key] = keyInfo[key]

      for  plugin in pluginInfo:
        let piname = plugin.name

        if plugin.configInfo.getCodec(): continue
        if not plugin.configInfo.getEnabled(): continue
        if not streamAvailable and plugin.configInfo.getUsesFstream():
          trace("Plugin {piname} skipped; codec {name} " &
                "does not supply required file stream")
          continue
        let
          pluginKeys     = plugin.configInfo.getKeys()
          pluginIgnores  = plugin.configInfo.getIgnore()
          overrides      = plugin.configInfo.getOverrides()
          isSystemPlugin = plugin in getSystemPlugins()
        var
          run = false

        for key in pluginKeys:
          if key in pluginIgnores: continue
          if key in overrides or key == "*" or key notin infoObj.newFields:
            run = true
            break

        if not run:
          trace(fmt"Plugin '{piname}': no work to do")
          infoObj.closeFileStream()
          continue

        trace(fmt"Running Plugin '{piname}'")
        let keyInfo = plugin.getArtifactInfo(infoObj)
        if keyInfo == nil or len(keyInfo) == 0:
          trace(fmt"Plugin '{piname}' returned no metadata.")
          continue
        for key, value in keyInfo:
          if key in overrides or key notin infoObj.newFields:
            if key notin everyKey:
              error(fmt"Plugin {piname} defines unspec'd key: {key}")
              continue
            if key.isSystemKey() and not isSystemPlugin:
              error(fmt"Plugin {piname} tries to write system key: {key}")
              continue
            infoObj.newFields[key] = value

      if not infoObj.isValidChalk():
        error("{path}: generated chalk object is invalid (skipping)")
      else:
        trace(fmt"{path}: chalk object built; injecting.")
        let toPublish = infoObj.doOneInjection(codec)
        objsForPublish.add(toPublish)

      # Should be totally done with the file stream now.
      infoObj.closeFileStream()
      popTargetChalkForErrorMsgs()

  let fullJson = "[" & join(objsForPublish, ", ") & "]"

  if getSelfInjecting():
    publish("confload", fullJson)
  else:
    publish("insert", fullJson)
