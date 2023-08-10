## :Author: John Viega, Theofilos Petsios
## :Copyright: 2023, Crash Override, Inc.

import posix, unicode, ../config, ../collect, ../reporting,
       ../chalkjson, ../docker_cmdline, ../docker_base, ../subscan,
       ../dockerfile, ../commands/cmd_defaults, ../util, ../attestation

{.warning[CStringConv]: off.}

proc launchDockerSubscan(ctx:     DockerInvocation,
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

proc writeChalkMark(ctx: DockerInvocation, mark: string) =
  # We are going to move this file, so don't autodelete.
  var
    (f, path) = getNewTempFile(autoDelete = false)

  try:
    info("Creating temporary chalk file: " & path)
    f.writeLine(mark)
    f.close()
    ctx.makeFileAvailableToDocker(path, true, "chalk.json")
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

proc addNewLabelsToDockerFile(ctx: DockerInvocation) =
  # First, add totally custom labels.
  let labelOps = chalkConfig.dockerConfig.getCustomLabels()

  if labelOps.isSome():
    for k, v in labelOps.get():
      ctx.addedInstructions.add(formatLabel(k, v, true))

  let labelProfileName = chalkConfig.dockerConfig.getLabelProfile()
  if labelProfileName == "":
    return

  let labelProfile = chalkConfig.profiles[labelProfileName]

  if not labelProfile.enabled:
    return

  let
    chalkObj    = ctx.opChalkObj.collectedData
    labelsToAdd = filterByProfile(hostInfo, chalkObj, labelProfile)

  for k, v in labelsToAdd:
    ctx.addedInstructions.add(formatLabel(k, boxToJson(v), true))

proc setPreferredTag(ctx: DockerInvocation) =
  # For now, we only add a tag if there are no found tags, and that is it.
  # Eventually we may let people define their own.

  if len(ctx.foundTags) == 0:
    ctx.ourTag      = chooseNewTag()
    ctx.prefTag     = ctx.ourTag
    ctx.newCmdLine &= @["-t", ctx.ourTag]

  else:
    ctx.prefTag = ctx.foundTags[0]

  ctx.opChalkObj.userRef = ctx.prefTag

proc writeNewDockerFile(ctx: DockerInvocation) =
  # TODO: can just plan to always send the Dockerfile on stdin, unless the
  # context was provided on stdin.

  if len(ctx.addedInstructions) == 0 and ctx.dockerFileLoc != ":stdin:":
    ctx.newCmdLine.add("-f")
    ctx.newCmdLine.add(ctx.dockerFileLoc)
    return

  let (f, path) = getNewTempFile()

  info("Created temporary Dockerfile at: " & path)

  f.write(ctx.inDockerFile)
  for line in ctx.addedInstructions:
    f.writeLine(line)
  f.close()

  ctx.newCmdLine.add("-f")
  ctx.newCmdLine.add(path)

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

proc handleTrueInsertion(ctx: DockerInvocation, mark: string) =
  if chalkConfig.dockerConfig.getWrapEntryPoint():
    ctx.rewriteEntryPoint()
  ctx.writeChalkMark(mark)

proc prepVirtualInsertion(ctx: DockerInvocation) =
  # Virtual insertion for Docker does not rewrite the entry point
  # either.

  if chalkConfig.dockerConfig.getWrapEntryPoint():
    warn("Cannot wrap entry point in virtual chalking mode.")

  let labelOps = chalkConfig.dockerConfig.getCustomLabels()

  if labelOps.isSome():
    for k, v in labelOps.get():
      ctx.newCmdLine.add("--label")
      ctx.newCmdline.add(k & "=" & escapeJson(v))

  let labelProfileName = chalkConfig.dockerConfig.getLabelProfile()
  if labelProfileName == "":
    return

  let labelProfile = chalkConfig.profiles[labelProfileName]

  if not labelProfile.enabled:
    return

  let
    chalkObj    = ctx.opChalkObj.collectedData
    labelsToAdd = filterByProfile(hostInfo, chalkObj, labelProfile)

  for k, v in labelsToAdd:
    ctx.newCmdLine.add("--label")
    ctx.addedInstructions.add(formatLabel(k, boxToJson(v), false))

proc addBuildCmdMetadataToMark(ctx: DockerInvocation) =
  let dict = ctx.opChalkObj.collectedData

  dict.setIfNeeded("DOCKERFILE_PATH", ctx.dockerFileLoc)
  dict.setIfNeeded("DOCKER_FILE", ctx.inDockerFile)
  dict.setIfNeeded("DOCKER_PLATFORM", ctx.foundPlatform)
  dict.setIfNeeded("DOCKER_LABELS", ctx.foundLabels)
  dict.setIfNeeded("DOCKER_TAGS", ctx.foundTags)
  dict.setIfNeeded("DOCKER_CONTEXT", ctx.foundContext)
  dict.setIfNeeded("DOCKER_ADDITIONAL_CONTEXTS", ctx.otherContexts)
  dict.setIfNeeded("DOCKER_CHALK_TEMPORARY_TAG", ctx.ourTag)
  dict.setIfNeeded("DOCKER_CHALK_ADDED_TO_DOCKERFILE",
                   ctx.addedInstructions.join("\n"))

proc prepareToBuild*(state: DockerInvocation) =
  info("Running docker build.")
  setCommandName("build")
  state.extractCmdlineBuildContext()
  state.loadDockerFile()
  # Sets up our replacement command line to be the same as before but
  # minus things that we change.
  state.stripFlagsWeRewrite()
  setContextDirectories(state.getAllDockerContexts())

proc runBuild(ctx: DockerInvocation): int =
  ctx.prepareToBuild()
  initCollection()

  let chalk       = newChalk(name         = ctx.prefTag,
                             resourceType = {ResourceImage},
                             codec        = Codec(getPluginByName("docker")))
  ctx.opChalkObj = chalk

  if not ctx.cmdPush:
    ctx.addBackAllOutputFlags()
  else:
    ctx.addBackOtherOutputFlags()
  if chalkConfig.getChalkContainedItems():
    info("Docker is starting a recursive chalk of context directories.")
    var contexts: seq[string] = @[ctx.foundContext]

    # It's alias=path
    for k, v in ctx.otherContexts:
      contexts.add(v)
    let
      subscanBox = ctx.launchDockerSubscan(contexts)
      unpacked   = unpack[seq[Box]](subscanBox)

    if len(unpacked) != 0:
      chalk.collectedData["EMBEDDED_CHALK"] = subscanBox
    info("Docker subscan finished.")

  ctx.evalAndExtractDockerfile()
  ctx.setPreferredTag()

  trace("Collecting chalkable artifact data")
  ctx.addBuildCmdMetadataToMark()
  chalk.collectChalkTimeArtifactInfo()

  trace("Creating chalk mark.")
  let chalkMark = chalk.getChalkMarkAsStr()

  if chalkConfig.getVirtualChalk():
    ctx.prepVirtualInsertion()
  else:
    ctx.handleTrueInsertion(chalkMark)
    ctx.addNewLabelsToDockerFile()
    ctx.writeNewDockerFile()

  # TODO: ctx.addEnvVarsToDockerfile()
  result = ctx.runWrappedDocker()

  if chalkConfig.getVirtualChalk() and result == 0:
    publish("virtual", chalkMark)

  chalk.marked = true

proc runPush(ctx: DockerInvocation): int =
  if ctx.cmdBuild:
    ctx.newCmdLine = @["push", ctx.prefTag]
    # Need to get imageID from the docker inspect.
    #handleExec(@[getMyAppPath()], @["docker", "push"]) # TODO from here
    # We're going to re-exec ourselves with an appropriate docker push command.
  else:
    initCollection()

    let chalk = ctx.getPushChalkObj()
    ctx.newCmdLine = ctx.originalArgs
    ctx.opChalkObj = chalk
    chalk.userRef  = ctx.prefTag

  # Here, if we fail, there's no re-run. Either (in the second branch), we
  # ran their original command line, or we've got nothing to fall back on,
  # because the build already succeeded.
  result = runDocker(ctx.newCmdLine)
  return result

# TODO: Any other noteworthy commands to wrap (run, etc)

template passThroughLogic() =
  try:
    # Silently pass through other docker commands right now.
    exitCode = runDocker(args)
    if chalkConfig.dockerConfig.getReportUnwrappedCommands():
      reporting.doReporting("report")
  except:
    dumpExOnDebug()
    reporting.doReporting("fail")

template gotBuildCommand() =
  try:
    exitCode = ctx.runBuild()
    if exitCode != 0:
      error("Docker failed with exit code: " & $(exitCode) &
            ". Retrying w/o chalk.")
      ctx.dockerFailsafe()
    else:
      if not ctx.opChalkObj.extractBasicImageInfo():
        error("Could not inspect image after successful build." &
          "Chalk reporting will be limited.")
  except:
    dumpExOnDebug()
    error("Chalk could not process Docker correctly. Retrying w/o chalk.")
    ctx.dockerFailSafe()

  trace("Collecting post-build runtime data")
  ctx.opChalkObj.collectRunTimeArtifactInfo()

template gotPushCommand() =
  try:
    exitCode = ctx.runPush()
    if exitCode != 0:
      error("Docker push operation failed with exit code: " & $(exitCode))
    else:
      info(ctx.opChalkObj.name & ": Successfully pushed")
      trace("Collecting post-push runtime data")
      ctx.opChalkObj.collectRunTimeArtifactInfo()
      if not ctx.cmdBuild:
        let
          mark = ctx.opChalkObj.dockerExtractChalkMark()

        if mark == nil:
          info(ctx.opChalkObj.name & ": Artifact is unchalked.")
        else:
          for k, v in mark:
            ctx.opChalkObj.collectedData[k] = v
            ctx.opChalkObj.extract          = mark
            ctx.opChalkObj.marked           = true
  except:
    error("Docker push operation failed.")
  exitCode = 0

template postDockerActivity() =
  if exitCode == 0:
    if canAttest():
      if not ctx.cmdBuild and ctx.opChalkObj.cachedMark == "":
        error(ctx.opChalkObj.name & ": Pushing an unchalked container.")
      else:
        info("Pushing attestation.")
        try:
          ctx.pushAttestation()
          info("Collecting post-push runtime data")
          ctx.opChalkObj.collectRunTimeArtifactInfo()
          trace("About to call into validate.")
          attestation.extractAndValidateSignature(ctx.opChalkObj)
        except:
          dumpExOnDebug()
          error("Docker attestation failed.")
    else:
        info("Attestation not configured.")
        # Build succeeded, so we want to report and exit 0, even if
        # the push failed.
        exitCode = 0

proc runCmdDocker*(args: seq[string]) =
  setDockerExeLocation()

  var
    exitCode = 0
    ctx      = args.processDockerCmdLine()

  ctx.originalArgs = args

  if ctx.cmdBuild:
    # Build with --push is still a build operation.
    setCommandName("build")
  elif ctx.cmdPush:
    setCommandName("push")

  if not ctx.cmdBuild and not ctx.cmdPush:
    passThroughLogic()
  else:
      forceArtifactKeys(["_REPO_TAGS", "_REPO_DIGESTS"])
      if ctx.cmdBuild:
        gotBuildCommand()

      if ctx.cmdPush:
        gotPushCommand()

      ctx.opChalkObj.addToAllChalks()

      postDockerActivity()

      if exitCode == 0:
        reporting.doReporting("report")

  # For paths that didn't call doReporting, which generally cleans these up.
  showConfig()
  quitChalk(exitCode)
