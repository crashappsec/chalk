##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/re
import "./docker"/[scan]
import "."/[config, plugin_api]

proc hasSubscribedKey(p: Plugin, keys: seq[string], dict: ChalkDict): bool =
  # Decides whether to run a given plugin... does it export any key we
  # are subscribed to, that hasn't already been provided?
  for k in keys:
    if k in attrGet[seq[string]]("plugin." & p.name & ".ignore"): continue
    if k notin subscribedKeys and k != "*": continue
    if k in attrGet[seq[string]]("plugin." & p.name & ".overrides"): return true
    if k notin dict:                return true

  return false

proc canWrite(plugin: Plugin, key: string, decls: seq[string]): bool =
  # This would all be redundant to what we can check in the config file spec,
  # except that we do allow "*" fields for plugins, so we need the runtime
  # check to filter out inappropriate items.
  let section = "keyspec." & key
  doAssert sectionExists(section)

  if key in attrGet[seq[string]]("plugin." & plugin.name & ".ignore"): return false

  if attrGet[bool](section & ".codec"):
    if attrGet[bool]("plugin." & plugin.name & ".codec"):
      return true
    else:
      error("Plugin '" & plugin.name & "' can't write codec key: '" & key & "'")
      return false

  if key notin decls and "*" notin decls:
    error("Plugin '" & plugin.name & "' produced undeclared key: '" & key & "'")
    return false
  if not attrGet[bool](section & ".system"):
    return true

  if plugin.isSystem():
    return true

  case plugin.name
  of "conffile":
    if attrGet[bool](section & ".conf_as_system"):
      return true
  else: discard

  error("Plugin '" & plugin.name & "' can't write system key: '" & key & "'")
  return false

proc registerKeys(templ: string) =
  let section = templ & ".key"
  if sectionExists(section):
    for name in getChalkSubsections(section):
      let content = section & "." & name
      let useOpt = attrGetOpt[bool](content & ".use")
      if useOpt.isSome() and useOpt.get():
        subscribedKeys[name] = true

proc collectChalkTimeHostInfo*() =
  if hostCollectionSuspended():
    return

  trace("Collecting chalk time artifact info")
  for plugin in getAllPlugins():
    let subscribed = attrGet[seq[string]]("plugin." & plugin.name & ".pre_run_keys")
    if chalkCollectionSuspendedFor(plugin.name):          continue
    if not plugin.hasSubscribedKey(subscribed, hostInfo): continue
    try:
      trace("Running plugin: " & plugin.name)
      let dict = plugin.callGetChalkTimeHostInfo()
      if dict == nil or len(dict) == 0:
        continue

      for k, v in dict:
        if not plugin.canWrite(k, attrGet[seq[string]]("plugin." & plugin.name & ".pre_run_keys")):
          trace(plugin.name & ": cannot write " & k & ". skipping")
          continue
        if k notin hostInfo or
            k in attrGet[seq[string]]("plugin." & plugin.name & ".overrides") or
            plugin.isSystem():
          hostInfo[k] = v
    except:
      error("When collecting chalk-time host info, plugin implementation " &
            plugin.name & " threw an exception it didn't handle: " & getCurrentExceptionMsg())
      dumpExOnDebug()

proc initCollection*(collectHost = true) =
  ## Chalk commands that report call this to initialize the collection
  ## system.  It looks at any reports that are currently configured,
  ## and 'registers' the keys, so that we don't waste time trying to
  ## collect data that isn't going to be reported upon.
  ##
  ## then, if we are chalking, it collects ChalkTimeHostInfo data

  trace("Collecting host-level chalk-time data")

  forceChalkKeys([
    "MAGIC",
    "CHALK_VERSION",
    "CHALK_ID",
    "METADATA_ID",
    "HASH",
  ])

  # We always subscribe to _VALIDATED, even if they don't want to
  # report it; they might subscribe to the error logs it generates.
  #
  # This basically ends up forcing getRunTimeArtifactInfo() to run in
  # the system plugin.
  #
  # TODO: The config should hand us a list of keys to force.
  subscribedKeys["_VALIDATED"] = true
  registerKeys(getMarkTemplate())
  registerKeys(getReportTemplate())

  # Next, register for any custom reports.
  for name in getChalkSubsections("custom_report"):
    let report = "custom_report." & name
    let useWhenOpt = attrGetOpt[seq[string]](report & ".use_when")
    if useWhenOpt.isSome():
      let useWhen = useWhenOpt.get()
      if (getBaseCommandName() notin useWhen and "*" notin useWhen):
        continue
    registerKeys(getReportTemplate(report))

  if isChalkingOp() and collectHost:
      collectChalkTimeHostInfo()

proc collectRunTimeArtifactInfo*(artifact: ChalkObj) =
  artifact.withErrorContext():
    trace("Collecting run time artifact info")
    for plugin in getAllPlugins():
      let
        data       = artifact.collectedData
        subscribed = attrGet[seq[string]]("plugin." & plugin.name & ".post_chalk_keys")

      if chalkCollectionSuspendedFor(plugin.name):               continue
      if not plugin.hasSubscribedKey(subscribed, data):          continue
      if attrGet[bool]("plugin." & plugin.name & ".codec") and plugin != artifact.myCodec: continue

      trace("Running plugin: " & plugin.name)
      try:
        let dict = plugin.callGetRunTimeArtifactInfo(artifact, isChalkingOp())
        if dict == nil or len(dict) == 0: continue
        for k, v in dict:
          if not plugin.canWrite(k, attrGet[seq[string]]("plugin." & plugin.name & ".post_chalk_keys")): continue
          if k notin artifact.collectedData or
              k in attrGet[seq[string]]("plugin." & plugin.name & ".overrides") or
              plugin.isSystem():
            artifact.collectedData[k] = v
        trace(plugin.name & ": Plugin called.")
      except:
        error("When collecting run-time artifact data, plugin implementation " &
              plugin.name & " threw an exception it didn't handle (artifact = " &
              artifact.name & "): " & getCurrentExceptionMsg())
        dumpExOnDebug()

    artifact.collectedData.setIfNeeded("_CURRENT_HASH", artifact.callGetEndingHash())

proc rtaiLinkingHack*(artifact: ChalkObj) {.cdecl, exportc.} =
  artifact.collectRunTimeArtifactInfo()

proc collectChalkTimeArtifactInfo*(obj: ChalkObj, override = false) =
  obj.withErrorContext():
    # Note that callers must have set obj.collectedData to something
    # non-null.
    obj.opFailed      = false
    let data          = obj.collectedData

    trace("Collecting chalk-time data.")
    for plugin in getAllPlugins():
      if chalkCollectionSuspendedFor(plugin.name): continue

      if plugin == obj.myCodec:
        trace("Filling in codec info")
        if "CHALK_ID" notin data:
          data["CHALK_ID"]      = pack(obj.callGetChalkId())
        data.setIfNeeded("HASH", obj.callGetUnchalkedHash())
        data.setIfNeeded("PRE_CHALK_HASH", obj.callGetPrechalkingHash())
        if obj.fsRef != "":
          data.setIfNeeded("PATH_WHEN_CHALKED", resolvePath(obj.fsRef))

      if attrGet[bool]("plugin." & plugin.name & ".codec") and plugin != obj.myCodec:
        continue

      if len(obj.resourceType * plugin.resourceTypes) == 0:
        continue

      let subscribed = attrGet[seq[string]]("plugin." & plugin.name & ".pre_chalk_keys")
      if not plugin.hasSubscribedKey(subscribed, data) and not plugin.isSystem():
        trace(plugin.name & ": Skipping plugin; its metadata wouldn't be used.")
        continue

      if plugin.getChalkTimeArtifactInfo == nil:
        continue

      trace("Running plugin: " & plugin.name)
      try:
        let dict = plugin.callGetChalkTimeArtifactInfo(obj)
        if dict == nil or len(dict) == 0:
          trace(plugin.name & ": Plugin produced no keys to use.")
          continue

        for k, v in dict:
          if not plugin.canWrite(k, attrGet[seq[string]]("plugin." & plugin.name & ".pre_chalk_keys")):
            trace(plugin.name & ": cannot write " & k & ". skipping")
            continue
          if k notin obj.collectedData or
              k in attrGet[seq[string]]("plugin." & plugin.name & ".overrides") or
              plugin.isSystem() or
              override:
            obj.collectedData[k] = v
        trace(plugin.name & ": Plugin called.")
      except:
        error("When collecting chalk-time artifact data, plugin implementation " &
              plugin.name & " threw an exception it didn't handle (artifact = " &
              obj.name & "): " & getCurrentExceptionMsg())
        dumpExOnDebug()

proc collectRunTimeHostInfo*() =
  if hostCollectionSuspended(): return
  ## Called from report generation in commands.nim, not the main
  ## artifact loop below.
  trace("Collecting run time host info")
  for plugin in getAllPlugins():
    let subscribed = attrGet[seq[string]]("plugin." & plugin.name & ".post_run_keys")
    if chalkCollectionSuspendedFor(plugin.name):          continue
    if not plugin.hasSubscribedKey(subscribed, hostInfo): continue

    trace("Running plugin: " & plugin.name)
    try:
      let dict = plugin.callGetRunTimeHostInfo(getAllChalks())
      if dict == nil or len(dict) == 0: continue

      for k, v in dict:
        if not plugin.canWrite(k, attrGet[seq[string]]("plugin." & plugin.name & ".post_run_keys")): continue
        if k notin hostInfo or
            k in attrGet[seq[string]]("plugin." & plugin.name & ".overrides") or
            plugin.isSystem():
          hostInfo[k] = v
    except:
      error("When collecting run-time host info, plugin implementation " &
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
        attrGet[seq[string]]("ignore_patterns")[i])
      trace("Developers: codecs should not be returning ignored artifacts.")
      return true

  return false

proc artSetupForExtract(argv: seq[string]): ArtifactIterationInfo =
  new result

  let selfPath = resolvePath(getMyAppPath())

  result.fileExclusions = @[selfPath]
  result.recurse        = attrGet[bool]("recursive")

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
    skipList = attrGet[seq[string]]("ignore_patterns")

  result.fileExclusions = @[selfPath]
  result.recurse        = attrGet[bool]("recursive")

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
        obj.withErrorContext():
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

          if not inSubscan() and not obj.forceIgnore and
             obj.name notin getUnmarked():
            obj.collectRunTimeArtifactInfo()

          yield obj

  if not inSubscan():
    if getCommandName() != "extract":
      for item in iterInfo.otherPaths:
        error(item & ": No such file or directory.")
    else:
      trace("Processing docker artifacts.")
      for item in iterInfo.otherPaths:
        trace("Processing artifact: " & item)
        let objOpt = scanLocalImageOrContainer(item)
        if objOpt.isNone():
          if len(iterInfo.filePaths) > 0:
            error(item & ": No file, image or container found with this name")
          else:
            error(item & ": No image or container found")
        else:
          let chalk = objOpt.get()
          chalk.withErrorContext():
            chalk.addToAllChalks()
            if chalk.extract == nil:
              info(chalk.name & ": Artifact is unchalked.")
            trace("Collecting artifact runtime info")
            chalk.collectRunTimeArtifactInfo()
            yield chalk
