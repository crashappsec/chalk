## Load information based on profiles.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import glob, config, util, plugin_api, util

# We collect things in four different places

type CKind = enum CkChalkInfo, CkPostRunInfo, CkHostInfo


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

proc registerProfileKeys(profiles: openarray[string]): int {.discardable.} =
  result = 0

  # We always subscribe to _VALIDATED, even if they don't want to
  # report it; they might subscribe to the error logs it generates.
  #
  # This basically ends up forcing getRunTimeArtifactInfo() to run in
  # the system plugin.
  subscribedKeys["_VALIDATED"] = true

  for item in profiles:
    if item == "" or chalkConfig.profiles[item].enabled == false: continue
    result = result + 1
    for name, content in chalkConfig.profiles[item].keys:
      if content.report: subscribedKeys[name] = true

proc collectChalkTimeHostInfo*() =
  if hostCollectionSuspended(): return
  for plugin in getPlugins():
    let subscribed = plugin.configInfo.preRunKeys
    if not plugin.hasSubscribedKey(subscribed, hostInfo): continue
    let dict = plugin.getChalkTimeHostInfo()
    if dict == nil or len(dict) == 0: continue

    for k, v in dict:
      if not plugin.canWrite(k, plugin.configInfo.preRunKeys): continue
      if k notin hostInfo or k in plugin.configInfo.overrides:
        hostInfo[k] = v

proc initCollection*() =
  ## Chalk commands that report call this to initialize the collection
  ## system.  It looks at any reports that are currently configured,
  ## and 'registers' the keys, so that we don't waste time trying to
  ## collect data that isn't going to be reported upon.
  ##
  ## then, if we are chalking, it collects ChalkTimeHostInfo data

  trace("Collecting host-level chalk-time data")
  let config       = getOutputConfig()
  let cmdprofnames = [config.chalk, config.hostreport, config.artifactReport,
                      config.invalidChalkReport]

  # First, deal with the default output configuration.
  if registerProfileKeys(cmdprofnames) == 0:
    error("FATAL: no output reporting configured (all specs in the " &
          "command's 'outconf' object are disabled")
    quitChalk(1)

  # Next, register for any custom reports.
  for name, report in chalkConfig.reportSpecs:
    if (getBaseCommandName() notin report.use_when and
        "*" notin report.use_when):
      continue
    registerProfileKeys([report.artifactReport,
                         report.hostReport,
                         report.invalidChalkReport])

  if isChalkingOp():
      collectChalkTimeHostInfo()

proc collectRunTimeArtifactInfo*(artifact: ChalkObj) =
  for plugin in getPlugins():
    let
      data       = artifact.collectedData
      subscribed = plugin.configInfo.postChalkKeys

    if not plugin.hasSubscribedKey(subscribed, data):          continue
    if plugin.configInfo.codec and plugin != artifact.myCodec: continue


    let dict = plugin.getRunTimeArtifactInfo(artifact, isChalkingOp())
    if dict == nil or len(dict) == 0: continue

    for k, v in dict:
      if not plugin.canWrite(k, plugin.configInfo.postChalkKeys): continue
      if k notin artifact.collectedData or k in plugin.configInfo.overrides:
        artifact.collectedData[k] = v

  let hashOpt = artifact.myCodec.getEndingHash(artifact)
  if hashOpt.isSome():
    artifact.collectedData["_CURRENT_HASH"] = pack(hashOpt.get())

proc collectChalkTimeArtifactInfo*(obj: ChalkObj) =
  # Note that callers must have set obj.collectedData to something
  # non-null.
  obj.opFailed      = false
  let data          = obj.collectedData

  trace("Collecting chalk-time data.")
  for plugin in getPlugins():
    if plugin == Plugin(obj.myCodec):
      trace("Filling in codec info")
      data["CHALK_ID"]      = pack(obj.myCodec.getChalkID(obj))
      let preHashOpt = obj.myCodec.getUnchalkedHash(obj)
      if preHashOpt.isSome():
        data["HASH"]          = pack(preHashOpt.get())
      if obj.fsRef != "":
        data["PATH_WHEN_CHALKED"] = pack(resolvePath(obj.fsRef))

    if plugin.configInfo.codec and plugin != obj.myCodec: continue

    let subscribed = plugin.configInfo.artifactKeys
    if not plugin.hasSubscribedKey(subscribed, data):
      trace(plugin.name & ": Skipping plugin; its metadata wouldn't be used.")
      continue

    let dict = plugin.getChalkTimeArtifactInfo(obj)
    if dict == nil or len(dict) == 0:
      trace(plugin.name & ": Plugin produced no keys to use.")
      continue

    for k, v in dict:
      if not plugin.canWrite(k, plugin.configInfo.artifactKeys): continue
      if k notin obj.collectedData or k in plugin.configInfo.overrides:
        obj.collectedData[k] = v

    trace(plugin.name & ": Plugin called.")

proc collectRunTimeHostInfo*() =
  if hostCollectionSuspended(): return
  ## Called from report generation in commands.nim, not the main
  ## artifact loop below.
  for plugin in getPlugins():
    let subscribed = plugin.configInfo.postRunKeys
    if not plugin.hasSubscribedKey(subscribed, hostInfo): continue

    let dict = plugin.getRunTimeHostInfo(getAllChalks())
    if dict == nil or len(dict) == 0: continue

    for k, v in dict:
      if not plugin.canWrite(k, plugin.configInfo.postRunKeys): continue
      if k notin hostInfo or k in plugin.configInfo.overrides:
        hostInfo[k] = v

# The two below functions are helpers for the artifacts() iterator
# and the self-extractor (in the case of findChalk anyway).
proc ignoreArtifact(path: string, globs: seq[glob.Glob]): bool {.inline.} =
  for item in globs:
    if path.matches(item): return true
  return false

proc artSetupForExtract(argv: seq[string]): ArtifactIterationInfo =
  new result

  result.fileExclusions = @[resolvePath(getMyAppPath())]
  result.recurse        = chalkConfig.getRecursive()

  for item in argv:
    let maybe = resolvePath(item)
    if dirExists(maybe) or fileExists(maybe):
      result.filePaths.add(maybe)
    else:
      result.otherPaths.add(item)

proc artSetupForInsertAndDelete(argv: seq[string]): ArtifactIterationInfo =
  new result

  result.fileExclusions = @[resolvePath(getMyAppPath())]
  result.recurse        = chalkConfig.getRecursive()

  for item in chalkConfig.getIgnorePatterns():
    result.skips.add(glob("**/" & item))

  if len(argv) == 0:
    result.filePaths.add(getCurrentDir())
  else:
    for item in argv:
      let maybe = resolvePath(item)
      if dirExists(maybe) or fileExists(maybe):
        result.filePaths.add(maybe)
      else:
        error(maybe & ": No such file or directory")

proc artSetupForExecAndEnv(argv: seq[string]): ArtifactIterationInfo =
  # For the moment.
  new result

  result.filePaths = argv

proc dockerExtractChalkMark*(chalk: ChalkObj): ChalkDict {.importc.}
proc extractAndValidateSignature*(chalk: ChalkObj) {.importc.}

proc getImageChalks(codec: Codec): seq[ChalkObj] {.importc.}
proc getContainerChalks(codec: Codec): seq[ChalkObj] {.importc.}
proc scanOne(codec: Codec, item: string): Option[ChalkObj] {.importc.}

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
    for codec in getCodecs():
      if codec.name == "docker":
        continue
      trace("Asking codec '" &  codec.name & "' to scan artifacts.")
      let chalks = codec.scanArtifactLocations(iterInfo)

      for obj in chalks:
        if obj.extract != nil and "MAGIC" in obj.extract:
          obj.marked = true

        if ResourceFile in obj.resourceType:
          discard obj.acquireFileStream()
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

        yield obj

        clearErrorObject()
        if not inSubscan() and not obj.forceIgnore and
           obj.name notin getUnmarked():
          obj.collectRuntimeArtifactInfo()
          obj.closeFileStream()

  if not inSubscan():
    if getCommandName() != "extract":
      for item in iterInfo.otherPaths:
        error(item & ": No such file or directory.")
    else:
      trace("Processing docker artifacts.")
      let docker = Codec(getPluginByName("docker"))
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

proc getPushChalkObj*(info: DockerInvocation): ChalkObj =
    let chalkOpt = scanOne(Codec(getPluginByName("docker")), info.prefTag)

    if chalkOpt.isNone():
      warn("Cannot find image; running docker normally.")
      info.dockerFailSafe()

    if chalkOpt.get().containerId != "":
      warn("Push references a container; giving up & running docker normally.")
      info.dockerFailSafe()

    return chalkOpt.get()
