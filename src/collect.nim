##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/re
import "."/[config, util, plugin_api]

proc hasSubscribedKey(p: Plugin, keys: seq[string], dict: ChalkDict): bool =
  # Decides whether to run a given plugin... does it export any key we
  # are subscribed to, that hasn't already been provided?
  for k in keys:
    if k in p.configInfo.ignore:            continue
    if k notin subscribedKeys and k != "*": continue
    if k in p.configInfo.overrides: return true
    if k notin dict:                return true

  return false

proc canWrite(plugin: Plugin, key: string, decls: seq[string]): bool =
  # This would all be redundant to what we can check in the config file spec,
  # except that we do allow "*" fields for plugins, so we need the runtime
  # check to filter out inappropriate items.
  let spec = chalkConfig.keySpecs[key]

  if key in plugin.configInfo.ignore: return false

  if spec.codec:
    if plugin.configInfo.codec:
      return true
    else:
      error("Plugin '" & plugin.name & "' can't write codec key: '" & key & "'")
      return false

  if key notin decls and "*" notin decls:
    error("Plugin '" & plugin.name & "' produced undeclared key: '" & key & "'")
    return false
  if not spec.system:
    return true

  case plugin.name
  of "system", "metsys":
    return true
  of "conffile":
    if spec.confAsSystem:
      return true
  else: discard

  error("Plugin '" & plugin.name & "' can't write system key: '" & key & "'")
  return false

proc registerKeys(templ: MarkTemplate | ReportTemplate) =
  for name, content in templ.keys:
    if content.use: subscribedKeys[name] = true

proc registerOutconfKeys() =
  # We always subscribe to _VALIDATED, even if they don't want to
  # report it; they might subscribe to the error logs it generates.
  #
  # This basically ends up forcing getRunTimeArtifactInfo() to run in
  # the system plugin.
  #
  # TODO: The config should hand us a list of keys to force.
  subscribedKeys["_VALIDATED"] = true

  let outconf = getOutputConfig()

  if outconf.markTemplate != "":
    chalkConfig.markTemplates[outConf.markTemplate].registerKeys()

  if outconf.reportTemplate != "":
    chalkConfig.reportTemplates[outConf.reportTemplate].registerKeys()

proc collectChalkTimeHostInfo*() =
  if hostCollectionSuspended():
    return

  for plugin in getAllPlugins():
    let subscribed = plugin.configInfo.preRunKeys
    if not plugin.hasSubscribedKey(subscribed, hostInfo):
      continue
    try:
      let dict = plugin.callGetChalkTimeHostInfo()
      if dict == nil or len(dict) == 0:
        continue

      for k, v in dict:
        if not plugin.canWrite(k, plugin.configInfo.preRunKeys):
          continue
        if k notin hostInfo or k in plugin.configInfo.overrides:
          hostInfo[k] = v
    except:
      warn("When collecting chalk-time host info, plugin implementation " &
           plugin.name & " threw an exception it didn't handle: " & getCurrentExceptionMsg())
      dumpExOnDebug()

proc initCollection*() =
  ## Chalk commands that report call this to initialize the collection
  ## system.  It looks at any reports that are currently configured,
  ## and 'registers' the keys, so that we don't waste time trying to
  ## collect data that isn't going to be reported upon.
  ##
  ## then, if we are chalking, it collects ChalkTimeHostInfo data

  trace("Collecting host-level chalk-time data")

  forceChalkKeys(["MAGIC", "CHALK_VERSION", "CHALK_ID", "METADATA_ID"])
  registerOutconfKeys()


  # Next, register for any custom reports.
  for name, report in chalkConfig.reportSpecs:
    if (getBaseCommandName() notin report.use_when and
        "*" notin report.use_when):
      continue

    let templName = report.reportTemplate

    if templName != "":
      chalkConfig.reportTemplates[templName].registerKeys()

  if isChalkingOp():
      collectChalkTimeHostInfo()

proc collectRunTimeArtifactInfo*(artifact: ChalkObj) =
  for plugin in getAllPlugins():
    let
      data       = artifact.collectedData
      subscribed = plugin.configInfo.postChalkKeys

    if not plugin.hasSubscribedKey(subscribed, data):          continue
    if plugin.configInfo.codec and plugin != artifact.myCodec: continue


    try:
      let dict = plugin.callGetRunTimeArtifactInfo(artifact, isChalkingOp())
      if dict == nil or len(dict) == 0: continue
      for k, v in dict:
        if not plugin.canWrite(k, plugin.configInfo.postChalkKeys): continue
        if k notin artifact.collectedData or k in plugin.configInfo.overrides:
          artifact.collectedData[k] = v
      trace(plugin.name & ": Plugin called.")
    except:
      warn("When collecting run-time artifact data, plugin implementation " &
           plugin.name & " threw an exception it didn't handle (artifact = " &
           artifact.name & "): " & getCurrentExceptionMsg())
      dumpExOnDebug()

  let hashOpt = artifact.callGetEndingHash()
  if hashOpt.isSome():
    artifact.collectedData["_CURRENT_HASH"] = pack(hashOpt.get())

proc rtaiLinkingHack*(artifact: ChalkObj) {.cdecl, exportc.} =
  artifact.collectRunTimeArtifactInfo()

proc collectChalkTimeArtifactInfo*(obj: ChalkObj) =
  # Note that callers must have set obj.collectedData to something
  # non-null.
  obj.opFailed      = false
  let data          = obj.collectedData

  trace("Collecting chalk-time data.")
  for plugin in getAllPlugins():
    trace("Running plugin: " & plugin.name)
    if plugin == obj.myCodec:
      trace("Filling in codec info")
      if "CHALK_ID" notin data:
        data["CHALK_ID"]      = pack(obj.callGetChalkID())
      let preHashOpt = obj.callGetUnchalkedHash()
      if preHashOpt.isSome():
        data["HASH"]          = pack(preHashOpt.get())
      if obj.fsRef != "":
        data["PATH_WHEN_CHALKED"] = pack(resolvePath(obj.fsRef))

    if plugin.configInfo.codec and plugin != obj.myCodec: continue

    let subscribed = plugin.configInfo.artifactKeys
    if not plugin.hasSubscribedKey(subscribed, data) and
       plugin.name notin ["system", "metsys"]:
      trace(plugin.name & ": Skipping plugin; its metadata wouldn't be used.")
      continue

    if plugin.getChalkTimeArtifactInfo == nil:
      continue

    try:
      let dict = plugin.callGetChalkTimeArtifactInfo(obj)
      if dict == nil or len(dict) == 0:
        trace(plugin.name & ": Plugin produced no keys to use.")
        continue

      for k, v in dict:
        if not plugin.canWrite(k, plugin.configInfo.artifactKeys): continue
        if k notin obj.collectedData or k in plugin.configInfo.overrides:
          obj.collectedData[k] = v
      trace(plugin.name & ": Plugin called.")
    except:
      warn("When collecting chalk-time artifact data, plugin implementation " &
           plugin.name & " threw an exception it didn't handle (artifact = " &
           obj.name & "): " & getCurrentExceptionMsg())
      dumpExOnDebug()

proc collectRunTimeHostInfo*() =
  if hostCollectionSuspended(): return
  ## Called from report generation in commands.nim, not the main
  ## artifact loop below.
  for plugin in getAllPlugins():
    let subscribed = plugin.configInfo.postRunKeys
    if not plugin.hasSubscribedKey(subscribed, hostInfo): continue

    try:
      let dict = plugin.callGetRunTimeHostInfo(getAllChalks())
      if dict == nil or len(dict) == 0: continue

      for k, v in dict:
        if not plugin.canWrite(k, plugin.configInfo.postRunKeys): continue
        if k notin hostInfo or k in plugin.configInfo.overrides:
          hostInfo[k] = v
    except:
      warn("When collecting run-time host info, plugin implementation " &
           plugin.name & " threw an exception it didn't handle: " &
           getCurrentExceptionMsg())
      dumpExOnDebug()


# The two below functions are helpers for the artifacts() iterator
# and the self-extractor (in the case of findChalk anyway).
proc ignoreArtifact(path: string, regexps: seq[Regex]): bool {.inline.} =
  # If plugins use the default implementation of scanning, then it
  # will already have checked the 'ignore' list. That short circuits
  # us much faster than letting plugins do a bunch of extraction, then
  # checking here, afterward.
  #
  # But, what if they forget to check?  We check again here, and give
  # an appropriate message, though at the trace level.

  for i, item in regexps:
    if path.match(item):
      trace(path & ": returned artifact ignored due to matching: " &
        chalkConfig.getIgnorePatterns()[i])
      trace("Developers: codecs should not be returning ignored artifacts.")
      return true

  return false

proc artSetupForExtract(argv: seq[string]): ArtifactIterationInfo =
  new result

  let selfPath = resolvePath(getMyAppPath())

  result.fileExclusions = @[selfPath]
  result.recurse        = chalkConfig.getRecursive()

  for item in argv:
    let maybe = resolvePath(item)

    if dirExists(maybe) or fileExists(maybe):
      if maybe == selfPath:
        result.fileExclusions = @[]
      result.filePaths.add(maybe)
    else:
      result.otherPaths.add(item)

proc artSetupForInsertAndDelete(argv: seq[string]): ArtifactIterationInfo =
  new result

  let
    selfPath = resolvePath(getMyAppPath())
    skipList = chalkConfig.getIgnorePatterns()

  result.fileExclusions = @[selfPath]
  result.recurse        = chalkConfig.getRecursive()

  for item in skipList:
    result.skips.add(re(item))

  if len(argv) == 0:
    result.filePaths.add(getCurrentDir())
  else:
    for item in argv:
      let maybe = resolvePath(item)
      if dirExists(maybe) or fileExists(maybe):
        if maybe == selfPath:
          error("Cannot use this command to modify this chalk executable. " &
            "Please use 'chalk load' to modify.")
        result.filePaths.add(maybe)
      else:
        error(maybe & ": No such file or directory")

proc artSetupForExecAndEnv(argv: seq[string]): ArtifactIterationInfo =
  # For the moment.
  new result

  result.filePaths = argv

proc dockerExtractChalkMark*(chalk: ChalkObj): ChalkDict {.importc.}
proc extractAndValidateSignature*(chalk: ChalkObj) {.importc.}

proc scanOne(codec: Plugin, item: string): Option[ChalkObj] {.importc.}

proc resolveAll(argv: seq[string]): seq[string] =
  for item in argv:
    result.add(resolvePath(item))

iterator artifacts*(argv: seq[string], notTmp=true): ChalkObj =
  var iterInfo: ArtifactIterationInfo

  if notTmp:
    case getBaseCommandName()
    of "insert", "delete":
      iterInfo = artSetupForInsertAndDelete(argv)
    of "extract":
      iterInfo = artSetupForExtract(argv)
    of "exec", "env":
      iterInfo = artSetupForExecAndEnv(argv)
  else:
      iterInfo = ArtifactIterationInfo(filePaths: resolveAll(argv))

  trace("Called artifacts() -- filepaths = " & $(iterInfo.filePaths) &
    "; otherPaths = " & $(iterInfo.otherPaths))

  # First, iterate over all our file system entries.
  if iterInfo.filePaths.len() != 0:
    for codec in getAllCodecs():
      if getNativeCodecsOnly() and hostOs notin codec.nativeObjPlatforms:
        continue
      if codec.name == "docker":
        continue
      trace("Asking codec '" &  codec.name & "' to scan artifacts.")
      let chalks = codec.scanArtifactLocations(iterInfo)

      for obj in chalks:
        iterInfo.fileExclusions.add(obj.fsRef)

        if obj.extract != nil and "MAGIC" in obj.extract:
          obj.marked = true

        if ResourceFile in obj.resourceType:
          if obj.fsRef == "":
            obj.fsRef = obj.name
            warn("Codec did not properly set the fsRef field.")

        let path = obj.fsRef
        if isChalkingOp():
          if path.ignoreArtifact(iterInfo.skips):
            if notTmp: addUnmarked(path)
            if obj.isMarked():
              info(path & ": Ignoring, but previously chalked")
            else:
              trace(path & ": ignoring artifact")
          else:
            if notTmp: obj.addToAllChalks()
            if obj.isMarked():
              info(path & ": Existing chalk mark extracted")
            else:
              trace(path & ": Currently unchalked")
        else:
          if notTmp: obj.addToAllChalks()
          if not obj.isMarked():
            if notTmp: addUnmarked(path)
            warn(path & ": Artifact is unchalked")
          else:
            for k, v in obj.extract:
              obj.collectedData[k] = v

            info(path & ": Chalk mark extracted")

        if getCommandName() in ["insert", "docker"]:
          obj.persistInternalValues()
        obj.chalkCloseStream()
        yield obj

        clearErrorObject()
        if not inSubscan() and not obj.forceIgnore and
           obj.name notin getUnmarked():
          obj.collectRuntimeArtifactInfo()
        obj.chalkCloseStream()

  if not inSubscan():
    if getCommandName() != "extract":
      for item in iterInfo.otherPaths:
        error(item & ": No such file or directory.")
    else:
      trace("Processing docker artifacts.")
      let docker = getPluginByName("docker")
      var chalks: seq[ChalkObj]
      for item in iterInfo.otherPaths:
        let objOpt = docker.scanOne(item)
        if objOpt.isNone():
          if len(iterInfo.filePaths) > 0:
            error(item & ": No file, image or container found with this name")
          else:
            error(item & ": No image or container found")
        else:
          chalks.add(objOpt.get())

      for item in chalks:
        trace("Processing artifact: " & item.name)
        item.addToAllChalks()
        trace("Collecting artifact runtime info")
        item.collectRuntimeArtifactInfo()
        let mark = item.dockerExtractChalkMark()
        if mark == nil:
          info(item.name & ": Artifact is unchalked.")
        else:
          for k, v in mark:
            item.collectedData[k] = v
          item.extract = mark
          item.marked = true
          item.extractAndValidateSignature()
        yield item
        clearErrorObject()

proc dockerFailsafe(info: DockerInvocation) {.importc.}

proc getPushChalkObj*(info: DockerInvocation): ChalkObj =
    let chalkOpt = scanOne(getPluginByName("docker"), info.prefTag)

    if chalkOpt.isNone():
      warn("Cannot find image; running docker normally.")
      info.dockerFailSafe()

    if chalkOpt.get().containerId != "":
      warn("Push references a container; giving up & running docker normally.")
      info.dockerFailSafe()

    return chalkOpt.get()
