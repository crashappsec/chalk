import resources
import types
import config
import plugins
import extract
import con4m # just for getOrElse()
import io/tobinary
import io/tojson

import os
import tables
import algorithm
import strformat
import streams
import std/tempfiles

const requiredCodecKeys = ["SRC_PATH", "FILE_NAME", "HASH", "HASH_FILES"]

type
  KeyPriorityInfo = tuple[priority: int, plugin: Plugin]
let noOverrides = newTable[string, int]()

proc populateOneSami(sami: SamiObj,
                     codec: Codec,
                     priorityInfo: TableRef[string, seq[KeyPriorityInfo]],
                     nonCodecPlugins: seq[Plugin]) =
  var
    currentPriorities: Table[string, int]
    runPlugin: bool
    keyPriorities: Table[string, int] # Track the lowest priority we've seen for a key.
    pri: int # current priority value we're looking at
    allPlugins = nonCodecPlugins

  allPlugins.add(codec)

  sami.newFields = SamiDict()

  for plugin in allPlugins:
    runPlugin = false
    var
      pluginKeys = plugin.configInfo.getKeys()
      overrides = getOrElse(plugin.configInfo.getOverrides(), noOverrides)

    if (pluginKeys.len() == 1) and (pluginKeys[0] == "*"):
      pluginKeys = getOrderedKeys()

    if plugin.configInfo.getCodec():
      for item in requiredCodecKeys:
        if not pluginKeys.contains(item):
          pluginKeys.add(item)

    for key in pluginKeys:
      pri = plugin.configInfo.getPriority()
      if key in overrides:
        pri = overrides[key]

      if currentPriorities.contains(key) and pri >= currentPriorities[key]:
        continue
        # No plugin has run to set this key, so we're definitely going
        # to run, even if someone else comes along and has a lowever
        # priority in an override (the codecs are sorted on their
        # overall priority order).
      runPlugin = true
      keyPriorities[key] = pri

    if not runPlugin: continue
    let ki = plugin.getArtifactInfo(sami)

    for k, v in ki:
      if not currentPriorities.contains(k):
        sami.newFields[k] = v
        currentPriorities[k] = keyPriorities[k]
      else:
        let i = currentPriorities[k]
        if keyPriorities[k] < i:
          currentPriorities[k] = keyPriorities[k]
          sami.newFields[k] = v

proc doInjection*() =
  var
    # At the end we'll ask each codec w/ SAMIs to write all at once, if merited.
    codecs: seq[Codec]
    # Attach the codec to SAMIs as 'loser' Codecs don't get queried for keys.
    pluginInfo: seq[KeyPriorityInfo]
    keys: seq[string]
    overrides: TableRef[string, int]
    priorityInfo = newTable[string, seq[KeyPriorityInfo]]()
  let
    everyKey = getOrderedKeys()

  doExtraction(onBehalfOfInjection = true)

  # We're going to build a list of priority ordering based on plugin.
  # For codecs, they only get called when the SAMI is being read/written by
  # that codec.
  #
  # Note that codecs HAVE to export certain keys, so we also add them in.
  for (piPriority, name, plugin) in getPluginsByPriority():
    keys = plugin.configInfo.getKeys()
    overrides = getOrElse(plugin.configInfo.getOverrides(), noOverrides)

    if plugin.configInfo.getCodec():
      let
        codec = cast[Codec](plugin)
        extracts = codec.getSamis()
      if len(extracts) == 0: continue
      codecs.add(codec)
      for item in requiredCodecKeys:
        if not keys.contains(item): keys.add(item)
    else:
      pluginInfo.add((piPriority, plugin))
      keys = plugin.configInfo.getKeys()
      overrides = getOrElse(plugin.configInfo.getOverrides(), noOverrides)

    for key in keys:
      let currentPriority = if key in overrides:
                              overrides[key]
                            else:
                              piPriority
      if key in priorityInfo:
        priorityInfo[key].add((currentPriority, plugin))
      else:
        priorityInfo[key] = @[(currentPriority, plugin)]

  # For wildcard items, we add to EVERY key.
  if priorityInfo.contains("*"):
    let starItems = priorityInfo["*"]
    priorityInfo.del("*")
    for key in everyKey:
      if key in priorityInfo:
        for (k, v) in starItems:
          priorityInfo[key].add((k, v))
      else:
        priorityInfo[key] = starItems

  # If codecs registered for wildcard,
  # Now, sort for each key by priority.
  for key, s in priorityInfo:
    var copy = s
    copy.sort()
    priorityInfo[key] = copy

  pluginInfo.sort()
  var pluginsOnly: seq[Plugin]
  for (_, pi) in pluginInfo:
    pluginsOnly.add(pi)

  for codec in codecs:
    let extracts = codec.getSamis()

    for item in extracts:
      populateOneSami(item, codec, priorityInfo, pluginsOnly)

      if getDryRun():
        forceInform(infWouldWrite.fmt())
      else:
        item.stream.setPosition(0)
        let
          point = item.primary
          pre = item.stream.readStr(point.startOffset)
          encoded = if Binary in item.flags:
                      item.createdToBinary()
                    else:
                      item.createdToJson()

        if point.endOffset > point.startOffset:
          item.stream.setPosition(point.endOffset)
        let
          post = item.stream.readAll()

        var
          f: File
          path: string
          ctx: FileStream

        try:
          (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
          ctx = newFileStream(f)
          codec.handleWrite(ctx, pre, encoded, post)
          if point.present:
            inform(infReplacedSami.fmt())
          else:
            inform(infNewSami.fmt())
        except:
          error(eCantInsert.fmt())
          removeFile(path)
        finally:
          if ctx != nil:
            ctx.close()
            try:
              moveFile(path, item.fullPath)
            except:
              removeFile(path)
              raise





