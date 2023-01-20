import options, tables, streams, algorithm, strutils, strformat, os,
       std/tempfiles
import nimutils, config, plugins, extract, io/[tobinary, tojson]

const
  requiredCodecKeys = ["ARTIFACT_PATH", "HASH", "HASH_FILES"]
  infNewSami        = "{item.fullpath}: new artifact metadata added."
  infReplacedSami   = "{item.fullpath}: artifact metadata replaced."
  eCantInsert       = "{item.fullpath}: insertion failed!"

type
  KeyPriorityInfo = tuple[priority: int, plugin: Plugin]
let noOverrides = newTable[string, int]()

var
  systeMetsys: array[2, Plugin]

proc getSystemPlugins(): array[2, Plugin] {.inline.} =
  once:
    systeMetsys = [getPluginByName("system"), getPluginByName("metsys")]

  return systeMetsys

proc populateOneSami(sami:            SamiObj,
                     codec:           Codec,
                     priorityInfo:    TableRef[string, seq[KeyPriorityInfo]],
                     nonCodecPlugins: seq[Plugin]) =
  var
    currentPriorities: Table[string, int]
    runPlugin:         bool
    keyPriorities:     Table[string, int] # Track the lowest priority we've
                                          # seen for a key.
    pri:               int # current priority value we're looking at
    allPlugins       = nonCodecPlugins

  allPlugins.add(codec)

  sami.newFields = SamiDict()

  for plugin in allPlugins:
    runPlugin = false
    var
      pluginKeys = plugin.configInfo.getKeys()
      overrides  = getOrElse(plugin.configInfo.getOverrides(), noOverrides)

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
        # to run, even if someone else comes along and has a lower
        # priority in an override (the codecs are sorted on their
        # overall priority order).
      runPlugin = true
      keyPriorities[key] = pri

    if not runPlugin: continue
    let ki = plugin.getArtifactInfo(sami)

    if ki == nil: continue

    # For keys that are spec'd as 'codec' or 'system', those can only
    # be set by codecs or the system plugin, respectively.  We enforce
    # that in this loop.

    for k, v in ki:
      if k.isSystemKey() and plugin notin getSystemPlugins():
        error("Invalid (non-system) attempt to set system key: " & k)
        continue
      if k.isCodecKey() and plugin != codec:
        error("Non-codec attempted to set codec key: " & k)
        continue
      if len(k) > 0 and k[0] != 'X':
        if not isBuiltinKey(k):
          sami.insertionError("Invalid key: " & k &
            " (custom keys must start with X)")
          continue
      if not currentPriorities.contains(k):
        sami.newFields[k]    = v
        currentPriorities[k] = keyPriorities[k]
      else:
        let i = currentPriorities[k]
        if keyPriorities[k] < i:
          currentPriorities[k] = keyPriorities[k]
          sami.newFields[k]    = v

proc doInjection*() =
  var
    # At the end we'll ask each codec w/ SAMIs to write all at once, if merited.
    codecs:        seq[Codec]
    # Attach the codec to SAMIs as 'loser' Codecs don't get queried for keys.
    pluginInfo:    seq[KeyPriorityInfo]
    keys:          seq[string]
    overrides:     TableRef[string, int]
    priorityInfo = newTable[string, seq[KeyPriorityInfo]]()
    objsForWrite:  seq[string] = @[]
  let
    everyKey    = getOrderedKeys()
    inDryRun    = getDryRun()
    extractions = doExtraction()

  # Anything we've extracted is for an artifact where we are about to
  # inject over it.  Report these to the "nesting" output stream.
  if extractions.isSome():
    publish("nesting", extractions.get())

  # It's possible to define a plugin via external command that writes
  # JSON to stdout.  This loads any such plugins specified in the
  # config file.
  loadCommandPlugins()

  trace("Beginning artifact metadata collection and injection.")
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
        codec    = cast[Codec](plugin)
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

      item.stream.setPosition(0)
      let
        outputPtrs = getOutputPointers()
        point = item.primary
        pre = item.stream.readStr(point.startOffset)
      var
        # Note that createdToBinary and createdToJson detrmine whether
        # to write individual fields based on the setting of the
        # metadata key's in_ptr property.
        encoded = if Binary in item.flags:
                    item.createdToBinary(outputPtrs)
                  else:
                    item.createdToJson(outputPtrs)

      # Here we are not yet calling into the codec to do the actual
      # write.  There may be additional places we need to output the
      # SAMI, especially when the one we're injecting is a small
      # pointer... we will be sending the full SAMI off somewhere.
      #
      # We pass the full SAMI off to these handlers; if we're
      # writing a pointer the codec will not write the whole thing.
      #
      # However, we write the blob all at once, after
      if outputPtrs or Binary in item.flags:
        objsForWrite.add(item.createdToJson())
      else:
        objsForWrite.add(encoded)

      # NOW, if we're in dry-run mode, we don't actually inject.
      if inDryRun:
        continue

      if point.endOffset > point.startOffset:
        item.stream.setPosition(point.endOffset)
      let
        post = item.stream.readAll()

      var
        f:    File
        path: string
        ctx:  FileStream

      try:
        (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
        ctx       = newFileStream(f)
        codec.handleWrite(ctx, pre, some(encoded), post)
        if point.present:
          info(infReplacedSami.fmt())
        else:
          info(infNewSami.fmt())
      except:
        error(eCantInsert.fmt())
        removeFile(path)
      finally:
        if ctx != nil:
          ctx.close()
          try:
            let newPath = if getSelfInjecting(): item.fullPath & ".new"
                          else: item.fullPath
            moveFile(path, newPath)
            if getSelfInjecting():
              info(fmt"Wrote new sami binary to {newpath}")
          except:
            removeFile(path)
            error("Could complete file write.")
            raise

  # Finally, if we've got external output requirements, it's time to
  # dump what we've read to the "inject" stream.

  let fullJson = "[" & join(objsForWrite, ", ") & "]"

  if getSelfInjecting():
    publish("confload", fullJson)
  else:
    publish("insert",   fullJson)
