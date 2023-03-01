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
  if codec.usesFStream():
    discard infoObj.acquireFileStream()

proc isValidChalk(obj: ChalkObj): bool =
  result = true
  for key in getRequiredKeys():
    if key notin obj.newFields:
      error(fmt"{obj.fullPath} is missing key: {key}")
      result = false

proc selfInject(obj: ChalkObj, codec: Codec): string =
  var
    f:    File
    path: string
    ctx:  FileStream

  try:
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
    ctx       = newFileStream(f)

    codec.handleWrite(obj, some(obj.createdToJson(false)))
    if obj.isMarked():
      info(fmt"{obj.fullPath}: self-injection metadata replaced.")
    else:
      info(fmt"{obj.fullPath}: new self-injection metadata added.")
  except:
    error(fmt"{obj.fullPath}: insertion failed: " & getCurrentExceptionMsg())
    removeFile(path)
    obj.closeFileStream()
  finally:
    if ctx != nil:
      ctx.close()
      try:
        let newPath = if getSelfInjecting(): obj.fullPath & ".new"
                      else: obj.fullPath
        moveFile(path, newPath)
        info(fmt"Wrote new binary with loading conf to {newpath}")
      except:
        removeFile(path)
        error(fmt"{obj.fullPath}: Could not write (no permission)")

proc doOneInjection(obj: ChalkObj, codec: Codec, deletion: bool): string =
  # Preps what needs to be written for one chalk before hitting up the
  # codec to do the actual writing.
  var op = if deletion: "deletion" else: "insertion"
  if getSelfInjecting():
    return selfInject(obj, codec)

  let
    flag     = getOutputPointers()
    toInject = if deletion: none(string) else: some(obj.createdToJson(flag))

  if deletion: result = ""
  else:        result = if flag: obj.createdToJson(false) else: toInject.get()

  if chalkConfig.getDryRun():
    info("{obj.fullPath}: would modify metadata; publishing to 'dry-run' instead")
    publish("dry-run", result)
    return
  elif deletion and not obj.isMarked(): return # Nothing to delete.
  try:
    codec.handleWrite(obj, some(obj.createdToJson(flag)))
    if deletion:
      info(obj.fullPath & ": artifact metadata deleted.")
    elif obj.startOffset < obj.endOffset:
      info(obj.fullPath & ": artifact metadata replaced.")
    else:
      info(obj.fullPath & ": artifact metadata added.")
  except:
    error(obj.fullPath & ": " & op & " failed: " & getCurrentExceptionMsg())

proc doInjection*(deletion = false) =
  var
    objsForPublish: seq[string] = @[]
  let
    codecs      = getCodecsByPriority()
    everyKey    = getOrderedKeys()
    inDryRun    = chalkConfig.getDryRun()
    extractions = doExtraction()
    pluginInfo  = getPluginsByPriority()

  # Anything we've extracted is for an artifact where we are about to
  # inject over it.  Report these to the "delete" output stream.
  if extractions.isSome():
    publish("delete", extractions.get())

  for plugin in codecs:
    let
      name            = plugin.name
      codec           = Codec(plugin)
      extracts        = codec.chalks
      codecIgnores    = codec.configInfo.getIgnore()
      xtraKeys        = codec.configInfo.getKeys()

    for infoObj in extracts:
      pushTargetChalkForErrorMsgs(infoObj)
      codec.acquireStreamIfUsed(infoObj)

      if deletion:
        discard infoObj.doOneInjection(codec, true)
        infoObj.closeFileStream()
        popTargetChalkForErrorMsgs()
        continue
      let
        keyInfo = codec.getArtifactInfo(infoObj)
        path    = infoObj.fullPath

      infoObj.newFields = ChalkDict()

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
        let toPublish = infoObj.doOneInjection(codec, false)
        objsForPublish.add(toPublish)

      # Should be totally done with the file stream now.
      infoObj.closeFileStream()
      popTargetChalkForErrorMsgs()

  if deletion: return
  let fullJson = "[" & join(objsForPublish, ", ") & "]"

  if getSelfInjecting():
    publish("confload", fullJson)
  else:
    publish("insert", fullJson)
