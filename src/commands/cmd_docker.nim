##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk docker` command logic.
##
## Whereas other commands use the `collect` module for their overall
## collection logic, docker is completely different, with two
## different paths where we do collection... chalk extraction, and
## when running docker.
##
## The bits in common to those two things are mainly handled in the
## docker Codec, or in chalk_base when more appropriate.
##
## The extract path still starts in `cmd_extract.nim`, which can even
## make its way into `collect.nim` if specific containers or images
## are requested on the command line.
##
## But when wrapping docker, this module does the bulk of the work and
## is responsible for all of the collection logic.

import posix, unicode, ../config, ../collect, ../reporting,
       ../chalkjson, ../docker_cmdline, ../docker_base, ../subscan,
       ../dockerfile, ../util, ../attestation, ../commands/cmd_help,
       ../plugin_api

{.warning[CStringConv]: off.}

proc runMungedDockerInvocation(ctx: DockerInvocation): int =
  var
    newStdin = "" # Indicated passthrough.
    args     = ctx.newCmdLine

  trace("Running docker: " & dockerExeLocation & " " & args.join(" "))

  if ctx.dfPassOnStdin:
    if not ctx.inDockerFile.endswith("\n"):
      ctx.inDockerFile &= "\n"
    newStdin = ctx.inDockerFile & ctx.addedInstructions.join("\n")
    trace("Passing on stdin: \n" & newStdin)

  result = runCmdNoOutputCapture(dockerExeLocation, args, newStdin)

proc doReporting*(topic: string){.importc.}

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
  # We are going to move this file, so don't autoclean.
  var
    (f, path) = getNewTempFile(autoClean = false)

  try:
    info("Creating temporary chalk file: " & path)
    f.writeLine(mark)
    f.close()
    ctx.makeFileAvailableToDocker(path, move=true, newName="chalk.json")
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
  trace("Formatting label: " & result)

proc addNewLabelsToDockerFile(ctx: DockerInvocation) =
  # First, add totally custom labels.
  let labelOps = chalkConfig.dockerConfig.getCustomLabels()

  if labelOps.isSome():
    for k, v in labelOps.get():
      ctx.addedInstructions.add(formatLabel(k, v, true))

  let labelTemplName = chalkConfig.dockerConfig.getLabelTemplate()
  if labelTemplName == "":
    return

  let labelTemplate = chalkConfig.markTemplates[labelTemplName]

  let
    chalkObj         = ctx.opChalkObj.collectedData
    hostLabelsToAdd  = hostInfo.filterByTemplate(labelTemplate)
    artLabelsToAdd   = chalkObj.filterByTemplate(labelTemplate)

  for k, v in hostLabelsToAdd:
    ctx.addedInstructions.add(formatLabel(k, boxToJson(v), true))

  for k, v in artLabelsToAdd:
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

  ctx.opChalkObj.name = ctx.prefTag
  ctx.opChalkObj.userRef = ctx.prefTag

proc writeNewDockerFileIfNeeded(ctx: DockerInvocation) =
  # If we're not changing the Docker file, then we add an explicit -f
  # specifying the location. This may not have been specified by the
  # user, but it is good to be explicit.
  if len(ctx.addedInstructions) == 0 and ctx.dockerFileLoc != ":stdin:":
    ctx.newCmdLine.add("-f")
    ctx.newCmdLine.add(ctx.dockerFileLoc)
    return

  # If the context is passed on stdin we keep it on stdin, so in that
  # case we do need to write out the Dockerfile. Otherwise, set the
  # flag telling us to pass it on stdin.

  if ctx.foundContext != "-":
    ctx.newCmdLine.add("-f")
    ctx.newCmdLine.add("-")
    ctx.dfPassOnStdin = true
    return

  # Otherwise, when we have to write out an actual Docker file, we
  # should properly be using a temporary file, because it's a place
  # we're generally guaranteed to be able to write.

  let (f, path) = getNewTempFile()

  info("Created temporary Dockerfile at: " & path)

  if ctx.inDockerFile.len() != 0 and ctx.inDockerFile[^1] != '\n':
    ctx.inDockerFile &= "\n"

  let newcontents = ctx.inDockerFile & ctx.addedInstructions.join("\n")

  trace("New docker file: \n" & newcontents)
  f.write(newcontents)
  f.close()

  ctx.newCmdLine.add("-f")
  ctx.newCmdLine.add(path)

template noBadJson(item: InfoBase) =
  if item.error != "":
    warn("Cannot wrap due to dockerfile JSON parse error.")
    return

proc getDefaultPlatformInfo(ctx: DockerInvocation): string =
  if ctx.foundPlatform != "":
    return ctx.foundPlatform

  let
    probeFile      = """
FROM alpine
ARG TARGETPLATFORM
RUN echo "CHALK_TARGET_PLATFORM=$TARGETPLATFORM"
"""
    tmpTag         = chooseNewTag()
    buildKitKey    = "DOCKER_BUILDKIT"
    buildKitKeySet = existsEnv(buildKitKey)
  var buildKitValue: string
  if buildKitKeySet:
    buildKitValue  = getEnv(buildKitKey)
  putEnv(buildKitKey, "1")
  let
    allOut = runDockerGetEverything(@["build", "-t", tmpTag, "-f",
                                          "-", "."], probeFile)
    stdErr = allOut.getStderr()
    parts  = stdErr.split("CHALK_TARGET_PLATFORM=")

  trace("Probing for current docker build platform:\n" & stdErr)

  if buildKitKeySet:
    # key was set before us, so restore whatever the value was
    putEnv(buildKitKey, buildKitValue)
  else:
    # key was not set, restore that state
    delEnv(buildKitKey)

  discard runDockerGetEverything(@["rmi", tmpTag])

  # This could fail if docker is borked or somesuch.
  if len(parts) < 2:
    warn("Could not find `CHALK_TARGET_PLATFORM=` in the output.")
    return ""

  # From here, we'll assume docker is reliable, so we can just look
  #  for the quote.
  let
    base = parts[1]
    ix   = base.find('"')

  if base[0] == '$':
    # ARG didn't get substituted, so this build arg isn't supported.
    return ""

  return base[0 ..< ix]

template noBinaryForPlatform(): string =
    warn("Cannot wrap; no chalk binary found for target platform: " &
      targetPlatform & "(build platform = " & buildPlatform & ")")
    ""
proc findProperBinaryToCopyIntoContainer(ctx: DockerInvocation): string =
  # Mapping nim platform names to docker ones is a PITA. We need to
  # know the default target platform whenever --platform isn't
  # explicitly provided anyway, so we just ask Docker to tell us both
  # the native build platform, and the default target platform.

  # Note that docker does have some name normalization rules. For
  # instance, I think linux/arm/v7 and linux/arm64 are supposed to be
  # the same. We currently only ever self-identify with the later, but
  # you can match both options to point to the same binary with the
  # `arch_binary_locations` field.

  var
   targetPlatform = ctx.getDefaultPlatformInfo()
   buildPlatform  = hostOs & "/" & hostCPU

  if targetPlatform == "":

    warn("Cannot wrap; container platform doesn't support the TARGETPLATFORM " &
      "build arg.")
    return ""

  if targetPlatform == buildPlatform:
    return getMyAppPath()

  let locOpt = chalkConfig.dockerConfig.getArchBinaryLocations()

  if locOpt.isNone():
    return noBinaryForPlatform()

  let locInfo = locOpt.get()

  if targetPlatform notin locInfo:
    return noBinaryForPlatform()

  result = locInfo[targetPlatform].resolvePath()

  if not result.isExecutable():
    warn("Cannot wrap: specified Chalk binary for target architecture is " &
         "not executable. (binary: " & result & ", arch: " & targetPlatform &
         ")")
    return ""

proc formatExecString(command: string): string =
  let
    parts = strutils.split(command, maxsplit = 1)
    name  = parts[0]
    args  = if len(parts) > 1:
              " -- " & parts[1]
            else:
              ""
  return strutils.strip("exec /chalk exec --exec-command-name " &
    name & args)

proc formatExecArray(args: JsonNode): string =
  let arr = `%*`(["/chalk", "exec", "--exec-command-name"])
  var i = 0
  for item in args.items():
    if i == 1:
      arr.add(`%`("--"))
    arr.add(item)
    i.inc()
  return $(arr)

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

  info("Attempting to wrap container entry point.")

  if lastCmd == nil and lastEntryPoint == nil:
    # TODO: probably could wrap a /bin/sh -c invocation, but
    # we would need to worry about how to get access to any
    # inherited CMD params.
    warn("Cannot wrap; no entry information found in Dockerfile")
    return

  let
    binaryToCopy = ctx.findProperBinaryToCopyIntoContainer()

  if binaryToCopy == "":
    # Already got a warning.
    return

  info("Wrapping entry point with this chalk binary: " & binaryToCopy)
  try:
    ctx.makeFileAvailableToDocker(binaryToCopy, move=false, chmod="0755",
                                  newname="chalk")
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
      newInstruction =  "ENTRYPOINT " & formatExecString(lastEntryPoint.str)
    else:
      newInstruction = "ENTRYPOINT " & formatExecArray(lastEntryPoint.json)
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
      newInstruction = "CMD " & formatExecString(lastCmd.str)
    else:
      newInstruction = "CMD " & formatExecArray(lastCmd.json)

  ctx.addedInstructions.add(newInstruction)
  info("Entry point wrapped.")
  trace("Added instructions: \n" & ctx.addedInstructions.join("\n"))

proc isValidEnvVarName(s: string): bool =
  if len(s) == 0 or (s[0] >= '0' and s[0] <= '9'):
    return false

  for ch in s:
    if ch.isAlphaNumeric() or ch == '_':
      continue
    return false

  return true

proc pullValueFromKey(ctx: DockerInvocation, k: string): string =
  if len(k) == 1:
    warn(k & ": Invalid; key to pull into ENV var must not be empty.")
    return ""
  let key = k[1 .. ^1]

  if key.startsWith("_"):
    warn(k & ": Invalid; cannot use run-time keys, only chalk-time keys.")

  if key notin chalkConfig.keyspecs:
    warn(key & ": Invalid for env var; Chalk key doesn't exist.")

  if key in hostInfo:
    return $(hostInfo[key])

  if key in ctx.opChalkObj.collectedData:
    return $(ctx.opChalkObj.collectedData[key])

  warn(key & ": key could not be collected. Skipping environment variable.")

proc addAnyExtraEnvVars(ctx: DockerInvocation) =
  var
    toAdd: seq[string] = @[]
    map                = chalkConfig.dockerConfig.getAdditionalEnvVars()
    value: string

  for k, v in map:
    if not k.isValidEnvVarName():
      warn("ENV var " & k & " NOT added. Environment vars may only have " &
        "Letters (which will be upper-cased), numbers, and underscores.")
      continue
    if v.startsWith("@"):
      value = ctx.pullValueFromKey(v)
      if value == "":
        continue
    else:
      value = v
    toAdd.add(k.toUpperAscii() & "=" & escapeJson(value))

  if len(toAdd) != 0:
    let newEnvLine = "ENV " & toAdd.join(" ")
    ctx.addedInstructions.add(newEnvLine)
    info("Added to Dockerfile: " & newEnvLine)

proc handleTrueInsertion(ctx: DockerInvocation, mark: string) =
  if chalkConfig.dockerConfig.getWrapEntryPoint():
    ctx.rewriteEntryPoint()
  ctx.addAnyExtraEnvVars()
  ctx.writeChalkMark(mark)

template addVirtualLabels(labelsToAdd: untyped) =
  for k, v in labelsToAdd:
    let val = boxToJson(v)

    if val.len() <= 2:
      continue

    ctx.newCmdLine.add("--label")
    ctx.newCmdLine.add(formatLabel(k, val, false))

proc prepVirtualInsertion(ctx: DockerInvocation) =
  # Virtual insertion for Docker does not rewrite the entry point
  # either.

  if chalkConfig.dockerConfig.getWrapEntryPoint():
    warn("Cannot wrap entry point in virtual chalking mode.")

  let labelOps = chalkConfig.dockerConfig.getCustomLabels()

  if labelOps.isSome():
    for k, v in labelOps.get():
      if unicode.strip(v).len() == 0:
        continue

      ctx.newCmdLine.add("--label")
      ctx.newCmdline.add(k & "=" & escapeJson(v))

  let labelTemplName = chalkConfig.dockerConfig.getLabelTemplate()
  if labelTemplName == "":
    return

  let labelTemplate = chalkConfig.markTemplates[labelTemplName]

  let
    chalkObj        = ctx.opChalkObj.collectedData
    hostLabelsToAdd = hostInfo.filterByTemplate(labelTemplate)
    artLabelsToAdd  = chalkObj.filterByTemplate(labelTemplate)

  addVirtualLabels(hostLabelsToAdd)
  addVirtualLabels(artLabelsToAdd)

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

proc prepareToBuild(state: DockerInvocation) =
  info("Running docker build.")
  setCommandName("build")
  state.loadDockerFile()
  # Sets up our replacement command line to be the same as before but
  # minus things that we change.
  state.stripFlagsWeRewrite()
  setContextDirectories(state.getAllDockerContexts())

proc runBuild(ctx: DockerInvocation): int =
  ctx.prepareToBuild()
  initCollection()

  let chalk       = newChalk(name         = ctx.prefTag,
                             # multi-platform builds should have same chalk id
                             chalkId      = ctx.chalkId,
                             resourceType = {ResourceImage},
                             codec        = getPluginByName("docker"))
  ctx.opChalkObj = chalk

  ctx.addBackBuildCommonPushFlags()
  if not ctx.cmdPush:
    ctx.addBackBuildWithoutPushFlags()
  else:
    ctx.addBackBuildWithPushFlags()
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
    ctx.writeNewDockerFileIfNeeded()

  result = ctx.runMungedDockerInvocation()

  if chalkConfig.getVirtualChalk() and result == 0:
    publish("virtual", chalkMark)

  chalk.marked = true

proc runPush(ctx: DockerInvocation): int =
  if ctx.cmdBuild:
    var tags = ctx.foundTags
    if len(tags) == 0:
      tags = @[ctx.prefTag]

    for tag in tags:
      trace("docker pushing: " & tag)
      ctx.newCmdLine = @["push", tag]
      result = runCmdNoOutputCapture(dockerExeLocation, ctx.newCmdLine)
      if result != 0:
        break

    # Here, if we fail, there's no re-run.
    # We've got nothing to fall back on, because the build already succeeded.

  else:
    initCollection()

    let chalk = ctx.getPushChalkObj()
    ctx.newCmdLine = ctx.originalArgs
    ctx.opChalkObj = chalk
    chalk.userRef  = ctx.prefTag

    # Here, if we fail, there's no re-run.
    # We ran their original command line so there is nothing to fall back on.
    return runCmdNoOutputCapture(dockerExeLocation, ctx.newCmdLine)

proc createAndPushManifest(ctx: DockerInvocation, platforms: seq[string]): int =
  # not a multi-platform build so manifest should not be used
  if len(platforms) < 2:
    return 0

  for tag in ctx.foundTags:
    var platformTags = @[tag]
    for platform in platforms:
      platformTags.add(ctx.getTagForPlatform(tag, platform))

    let exitCode = runCmdNoOutputCapture(
      dockerExeLocation,
      @["buildx", "imagetools", "create", "-t"] & platformTags,
    )
    if exitCode != 0:
      error(tag & ": Could not push multi-platform manifest")
      return exitCode

    info(tag & ": Successfully pushed multi-platform manifest")

  # all tags succeded
  return 0

# TODO: Any other noteworthy commands to wrap (run, etc)

template passThroughLogic() =
  try:
    # Silently pass through other docker commands right now.
    exitCode = runCmdNoOutputCapture(dockerExeLocation, args)
    if chalkConfig.dockerConfig.getReportUnwrappedCommands():
      reporting.doReporting("report")
  except:
    dumpExOnDebug()
    reporting.doReporting("fail")

template prepBuildCommand() =
  try:
    ctx.processGitContext()
  except:
    dumpExOnDebug()
    error("Chalk could not process docker git context. Retrying w/o chalk.")
    ctx.dockerFailSafe()

template gotBuildCommand() =
  try:
    exitCode = ctx.runBuild()
    if exitCode != 0:
      error("Docker failed with exit code: " & $(exitCode) &
            ". Retrying w/o chalk.")
      ctx.dockerFailsafe()
    else:
      if not ctx.opChalkObj.extractBasicImageInfo():
        error("Could not inspect image after successful build. " &
          "Chalk reporting will be limited.")
  except:
    dumpExOnDebug()
    error("Chalk could not process Docker correctly. Retrying w/o chalk.")
    ctx.dockerFailSafe()

  trace("Collecting post-build runtime data")
  ctx.opChalkObj.collectRunTimeArtifactInfo()

template runBuildForSinglePlatform(platform: string) =
  trace("Docker building --platform=" & platform)
  let
    foundPlatform     = ctx.foundPlatform
    foundTags         = ctx.foundTags
    addedInstructions = ctx.addedInstructions
  ctx.foundPlatform = platform
  ctx.foundTags     = ctx.getTagsForPlatform(platform)
  try:
    gotBuildCommand()
    if ctx.cmdPush:
      gotPushCommand()
    # note this will add global chalk which means
    # even if later platform builds fail, all successful
    # builds will still be accounted for
    ctx.opChalkObj.addToAllChalks()
    postDockerActivity()
  finally:
    ctx.foundPlatform = foundPlatform
    ctx.foundTags = foundTags
    ctx.addedInstructions = addedInstructions

template gotPushCommand() =
  try:
    exitCode = ctx.runPush()
    if exitCode != 0:
      error("Docker push operation failed with exit code: " & $(exitCode))
      if "buildx" in ctx.originalArgs:
        error("Buildx use detected. Retrying w/o chalk.")
        # as buildx has independent configuration from docker daemon
        # there could be different insecure registry configurations.
        # Therefore buildx might be able to push but docker daemon might not:
        # * docker buildx build --push
        # * docker push
        # Since there is no buildx equivalent command just for pushing
        # built images, we have to fallback to default docker buildx build
        # which will build and push at the same time
        # otherwise chalk might be breaking existing builds
        ctx.dockerFailSafe()
      else:
        # note that if push fails we do not fallback to default docker behavior
        # as build must of succedded to get to push
        # and so it must be a registry error vs a chalk bug so we leave it as is
        # however note that chalk will still exit with non-zero exit code
        # not to change semantics of docker push or docker build --push commands
        discard
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
    ctx.dockerFailSafe()

template runMultiPlatformManifest() =
  try:
    exitCode = ctx.createAndPushManifest(platforms)
  except:
    exitCode = 1
    dumpExOnDebug()

  if exitCode != 0:
    # docker manifest features are experimental so we fallback for safety
    # from docker manifest --help:
    # > EXPERIMENTAL:
    # >   docker manifest is an experimental feature.
    # >   Experimental features provide early access to product functionality. These
    # >   features may change between releases without warning, or can be removed from a
    # >   future release. Learn more about experimental features in our documentation:
    # >   https://docs.docker.com/go/experimental/
    error("Chalk could not process Docker manifest correctly. Retrying w/o chalk.")
    ctx.dockerFailSafe()

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
    prepBuildCommand()

  elif ctx.cmdPush:
    setCommandName("push")

  if not ctx.cmdBuild and not ctx.cmdPush:
    passThroughLogic()

  # build --push --platform=X,Y,...
  elif ctx.cmdBuild and ctx.isMultiPlatform():
    trace("Detected multi-platform docker build. Splitting into individual platform builds")

    # force DOCKER_PLATFORM to be included in chalk normalization
    # which is required to compute unique METADATA_* keys
    forceChalkKeys(["DOCKER_PLATFORM"])
    forceReportKeys(["_REPO_TAGS", "_REPO_DIGESTS"])
    let platforms = ctx.getPlatforms()

    for platform in platforms:
      # only execute subsequent builds if all previous builds succeeded
      if exitCode == 0:
        runBuildForSinglePlatform(platform)

    if ctx.cmdPush and exitCode == 0:
      runMultiPlatformManifest()

    if exitCode == 0:
      reporting.doReporting("report")

  else:
    forceReportKeys(["_REPO_TAGS", "_REPO_DIGESTS"])
    if ctx.cmdBuild:
      gotBuildCommand()

    if ctx.cmdPush:
      gotPushCommand()

    ctx.opChalkObj.addToAllChalks()

    postDockerActivity()

    if exitCode == 0:
      reporting.doReporting("report")

  # For paths that didn't call doReporting, which generally cleans these up.
  showConfigValues()
  quitChalk(exitCode)
