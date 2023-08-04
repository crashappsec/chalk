import std/tempfiles, posix, unicode, ../config, ../collect, ../reporting,
       ../chalkjson, ../docker_cmdline, ../docker_base, ../subscan,
       ../dockerfile

{.warning[CStringConv]: off.}

proc launchDockerSubscan(info:     DockerInvocation,
                         contexts: seq[string]): Box =

  var usableContexts: seq[string]

  for context in contexts:
    if context == "-":
      warn("Currently cannot sub-chalk contexts passed via stdin.")
      continue
    if ':' in context:
      warn("Cannot sub-chalk remote context: " & context & " (skipping)")
      continue
    try:
      discard context.resolvePath().getFileInfo()
      usableContexts.add(context)
    except:
      warn("Cannot find context directory for subscan: " & context)
      continue

  if len(usableContexts) == 0:
    warn("No context sub scanning performed.")

  trace("Beginning docker subscan.")
  result = runChalkSubScan(usableContexts, "insert").report
  trace("Docker subscan complete.")

proc writeChalkMark(info: DockerInvocation, mark: string) =
  var
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
    ctx       = newFileStream(f)

  if f == nil:
    error("Unable to create a tmp file for Docker chalk mark")
    raise newException(ValueError, "fs open")
  try:
    info("Creating temporary chalk file: " & path)
    ctx.writeLine(mark)
    ctx.close()
    info.makeFileAvailableToDocker(path, true, "chalk.json")
  except:
    error("Unable to write to open tmp file (disk space?)")
    raise newException(ValueError, "fs write")

var labelPrefix: string

proc processLabelKey(s: string): string =
  once:
    labelPrefix = chalkConfig.dockerConfig.getLabelPrefix()

  result = labelPrefix

  if not labelPrefix.endsWith('.'):
    result &= "."

  result &= s

  result = result.toLowerAscii()
  result = result.replace("_", "-")
  if result.contains("$"):
    result = result.replace("$", "_")

template processLabelValue(v: string): string =
  if v.startswith('"') and v[^1] == '"' and len(v) > 1: v else: escapeJson(v)

proc formatLabel(name: string, value: string, addLabel: bool): string =
  if addLabel:
    result = "LABEL "
  result &= processLabelKey(name) & "=" & processLabelValue(value)

proc addNewLabelsToDockerFile(info: DockerInvocation) =
  # First, add totally custom labels.
  let labelOps = chalkConfig.dockerConfig.getCustomLabels()

  if labelOps.isSome():
    for k, v in labelOps.get():
      info.addedInstructions.add(formatLabel(k, v, true))

  let labelProfileName = chalkConfig.dockerConfig.getLabelProfile()
  if labelProfileName == "":
    return

  let labelProfile = chalkConfig.profiles[labelProfileName]

  if not labelProfile.enabled:
    return

  let
    chalkObj    = info.opChalkObj.collectedData
    labelsToAdd = filterByProfile(hostInfo, chalkObj, labelProfile)

  for k, v in labelsToAdd:
    info.addedInstructions.add(formatLabel(k, boxToJson(v), true))

proc setPreferredTag(info: DockerInvocation) =
  # For now, we only add a tag if there are no found tags, and that is it.
  # Eventually we may let people define their own.

  if len(info.foundTags) == 0:
    info.ourTag      = chooseNewTag()
    info.prefTag     = info.ourTag
    info.newCmdLine &= @["-t", info.ourTag]

  else:
    info.prefTag = info.foundTags[0]

  info.opChalkObj.tagRef = info.prefTag

  trace("Docker tag we'll use is " & info.prefTag)

proc writeNewDockerFile(info: DockerInvocation) =
  # TODO: can just plan to always send the Dockerfile on stdin, unless the
  # context was provided on stdin.

  if len(info.addedInstructions) == 0 and info.dockerFileLoc != ":stdin:":
    info.newCmdLine.add("-f")
    info.newCmdLine.add(info.dockerFileLoc)
    return

  let (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)

  info.tmpFiles.add(path)

  if f == nil:
    warn("Chalk cannot process; cannot create temporary files")
    raise newException(ValueError, "tmpfile")

  info("Created temporary Dockerfile: " & path)

  f.write(info.inDockerFile)
  for line in info.addedInstructions:
    f.writeLine(line)
  f.close()

  info.newCmdLine.add("-f")
  info.newCmdLine.add(path)

proc removeDockerTemporaryFiles(info: DockerInvocation) =
  for item in info.tmpFiles:
    trace("Removing tmp file: " & item)
    removeFile(item)

template noBadJson(item: InfoBase) =
  if item.error != "":
    warn("Cannot wrap due to dockerfile JSON parse error.")
    return

proc rewriteEntryPoint*(ctx: DockerInvocation) =
  var
    lastEntryPoint = EntryPointInfo(nil)
    lastCmd        = CmdInfo(nil)
    newInstruction: string

  for section in ctx.dfSections:
    if section.entryPoint != nil:
      section.entryPoint.noBadJson()
      lastEntryPoint = section.entryPoint

    if section.cmd != nil:
      section.cmd.noBadJson()
      lastCmd = section.cmd

  if lastCmd == nil and lastEntryPoint == nil:
    # TODO: probably could wrap a /bin/sh -c invocation, but
    # we would need to worry about how to get access to any
    # inherited CMD params.
    warn("Cannot wrap; no entry information found in Dockerfile")
    return

  try:
    ctx.makeFileAvailableToDocker(getMyAppPath(), false, "chalk")
  except:
    warn("Wrapping canceled; no available method to wrap entry point.")
    return

  if lastEntryPoint != nil:
    # When they specify ENTRYPOINT, we can safely ignore CMD, because
    # either ENTRYPOINT is in JSON (in which case CMD will get used but
    # will stay the same) or it will be a string, in which case CMD
    # will get ignored, as long as we keep ENTRYPOINT in string form.
    if lastEntryPoint.str != "":
      # In shell form, be a good citizen and exec so that `sh` isn't pid 1
      newInstruction =  "ENTRYPOINT exec /chalk exec --exec-command-name " &
        lastEntryPoint.str
    else:
      let arr = `%*`(["/chalk", "exec", "--exec-command-name"])
      for item in lastEntryPoint.json.items():
        arr.add(item)

      newInstruction = "ENTRYPOINT " & $(arr)
  else:
      # If we only have a CMD:
      # 1. shell form executes the full thing.
      # 2. exec form I *think* the args are always passed and it could
      #    be lifted to a ENTRYPOINT; I need to validate. If I'm wrong,
      #    then we have to chop off the first item in the CMD .
      #
      # Right now, we add in a new CMD, which should override the old one.
      # If not, we'll have to explicitly skip it.

    if lastCmd.str != "":
      newInstruction = "CMD exec /chalk exec --exec-command-name " &
        lastCmd.str
    else:
      let arr = `%*`(["/chalk", "exec", "--exec-command-name"])
      for item in lastCmd.json.items():
        arr.add(item)

      newInstruction = "CMD " & $(arr)

  ctx.addedInstructions.add(newInstruction)

proc handleTrueInsertion(info: DockerInvocation, mark: string) =
  if chalkConfig.dockerConfig.getWrapEntryPoint():
    info.rewriteEntryPoint()
  info.writeChalkMark(mark)

proc prepVirtualInsertion(info: DockerInvocation) =
  # Virtual insertion for Docker does not rewrite the entry point
  # either.

  if chalkConfig.dockerConfig.getWrapEntryPoint():
    warn("Cannot wrap entry point in virtual chalking mode.")

  let labelOps = chalkConfig.dockerConfig.getCustomLabels()

  if labelOps.isSome():
    for k, v in labelOps.get():
      info.newCmdLine.add("--label")
      info.newCmdline.add(k & "=" & escapeJson(v))

  let labelProfileName = chalkConfig.dockerConfig.getLabelProfile()
  if labelProfileName == "":
    return

  let labelProfile = chalkConfig.profiles[labelProfileName]

  if not labelProfile.enabled:
    return

  let
    chalkObj    = info.opChalkObj.collectedData
    labelsToAdd = filterByProfile(hostInfo, chalkObj, labelProfile)

  for k, v in labelsToAdd:
    info.newCmdLine.add("--label")
    info.addedInstructions.add(formatLabel(k, boxToJson(v), false))

proc addBuildCmdMetadataToMark(info: DockerInvocation) =
  let dict = info.opChalkObj.collectedData

  dict.setIfNeeded("DOCKERFILE_PATH", info.dockerFileLoc)
  dict.setIfNeeded("DOCKER_FILE", info.inDockerFile)
  dict.setIfNeeded("DOCKER_PLATFORM", info.foundPlatform)
  dict.setIfNeeded("DOCKER_LABELS", info.foundLabels)
  dict.setIfNeeded("DOCKER_TAGS", info.foundTags)
  dict.setIfNeeded("DOCKER_CONTEXT", info.foundContext)
  dict.setIfNeeded("DOCKER_ADDITIONAL_CONTEXTS", info.otherContexts)
  dict.setIfNeeded("DOCKER_CHALK_TEMPORARY_TAG", info.ourTag)
  dict.setIfNeeded("DOCKER_CHALK_ADDED_TO_DOCKERFILE",
                   info.addedInstructions.join("\n"))

proc prepareToBuild*(state: DockerInvocation) =
  info("Running docker build.")
  setCommandName("build")
  state.extractCmdlineBuildContext()
  state.loadDockerFile()
  # Sets up our replacement command line to be the same as before but
  # minus things that we change.
  state.stripFlagsWeRewrite()
  setContextDirectories(state.getAllDockerContexts())


proc runBuild(info: DockerInvocation): int =
  info.prepareToBuild()
  initCollection()

  let chalk       = newChalk(name         = info.getDockerFileLoc(),
                             resourceType = {ResourceImage},
                             codec        = Codec(getPluginByName("docker")))
  info.opChalkObj = chalk
  chalk.addToAllChalks()

  if not info.cmdPush:
    info.addBackAllOutputFlags()
  else:
    info.addBackOtherOutputFlags()
  if chalkConfig.getChalkContainedItems():
    info("Docker is starting a recursive chalk of context directories.")
    var contexts: seq[string] = @[info.foundContext]

    # It's alias=path
    for k, v in info.otherContexts:
      contexts.add(v)
    let
      subscanBox = info.launchDockerSubscan(contexts)
      unpacked   = unpack[seq[Box]](subscanBox)

    if len(unpacked) != 0:
      chalk.collectedData["EMBEDDED_CHALK"] = subscanBox
    info("Docker subscan finished.")

  info.evalAndExtractDockerfile()
  info.setPreferredTag()

  trace("Collecting chalkable artifact data")
  info.addBuildCmdMetadataToMark()
  chalk.collectChalkTimeArtifactInfo()

  trace("Creating chalk mark.")
  let chalkMark = chalk.getChalkMarkAsStr()

  if chalkConfig.getVirtualChalk():
    info.prepVirtualInsertion()
  else:
    info.handleTrueInsertion(chalkMark)
    info.addNewLabelsToDockerFile()
    info.writeNewDockerFile()

  # TODO: info.addEnvVarsToDockerfile()
  result = info.runWrappedDocker()

  if chalkConfig.getVirtualChalk() and result == 0:
    publish("virtual", chalkMark)

  trace("Collecting post-build runtime data and reporting")
  chalk.collectRunTimeArtifactInfo()
  doReporting("report")

proc runPush(info: DockerInvocation): int =
  setCommandName("push")

  if info.cmdBuild:
    info.newCmdLine = @["push", info.prefTag]
    # Need to get imageID from the docker inspect.
    #handleExec(@[getMyAppPath()], @["docker", "push"]) # TODO from here
    # We're going to re-exec ourselves with an appropriate docker push command.
  else:
    let chalk       = newChalk(name         = info.getDockerFileLoc(),
                               resourceType = {ResourceImage},
                               codec        = Codec(getPluginByName("docker")))
    initCollection()
    info.newCmdLine = info.originalArgs
    info.opChalkObj = chalk
    chalk.tagRef    = info.prefTag

    chalk.addToAllChalks()
  try:
    # Here, if we fail, there's no re-run. Either (in the second branch), we
    # ran their original command line, or we've got nothing to fall back on,
    # because the build already succeeded.
    result = runDocker(info.newCmdLine)
    if result != 0:
      error("Push operation failed.")
      doReporting("fail")
      return result

  except:
    error("Push operation failed.")
    doReporting("fail")
    return -1

  trace("Collecting post-push runtime data and reporting")
  forceHostKeys(["_REPO_PORT", "_REPO_HOST"])
  info.opChalkObj.collectRunTimeArtifactInfo()
  doReporting("report")

# TODO: Any other noteworthy commands to wrap (run, etc)

proc runCmdDocker*(args: seq[string]) =

  setDockerExeLocation()

  var
    exitCode: int   = 0
    info            = args.processDockerCmdLine()
  info.originalArgs = args

  try:
    if info.cmdBuild:
      exitCode = info.runBuild()
    if exitCode == 0 and info.cmdPush:
      exitCode = info.runPush()
    elif not info.cmdBuild:
      # Silently pass through other docker commands right now.
      exitCode = runDocker(args)
  except:
    dumpExOnDebug()
    if info.dockerFileLoc == ":stdin:":
      exitCode = runWrappedDocker(args, info.inDockerFile)
    else:
      exitCode = runDocker(args)
    doReporting("fail")
  finally:
    info.removeDockerTemporaryFiles()

  quit(exitCode)
