##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[config, collect, chalkjson, plugin_api, subscan, util]
import "."/[base, collect, ids, dockerfile, inspect, git, exe, entrypoint, platform, wrap, util]

proc processGitContext(ctx: DockerInvocation) =
  try:
    if isGitContext(ctx.foundContext):
      trace("docker: detected git docker context. Fetching context")
      ctx.gitContext = gitContext(ctx.foundContext,
                                  authTokenSecret = ctx.getSecret("GIT_AUTH_TOKEN"),
                                  authHeaderSecret = ctx.getSecret("GIT_AUTH_HEADER"))
      if not supportsBuildContextFlag():
        trace("docker: no support for additional contexts detected. " &
              "Checking out git context to disk")
        # if using git context, and buildx is not used which supports
        # --build-context args, in order to copy any files into container
        # we need to normalize context to a regular folder and so
        # we checkout git context into a folder and use that as context
        ctx.foundContext = ctx.gitContext.checkout()
  except:
    error("docker: chalk could not process docker git context: " & ctx.foundContext)
    raise

proc processDockerFile(state: DockerInvocation) =
  if state.dockerFileLoc == ":stdin:":
    let input           = stdin.readAll()
    state.inDockerFile  = input
    state.originalStdIn = input
    trace("docker: read Dockerfile from stdin")

  elif state.gitContext != nil and supportsBuildContextFlag():
    # state.dockerFileLoc is resolvedPath which is invalid
    # in git context as we need raw path passed in the CLI
    var dockerFileLoc = state.foundFileArg
    if dockerFileLoc == "":
      dockerFileLoc = "Dockerfile"
    state.inDockerFile = state.gitContext.show(dockerFileLoc)
    state.dockerFileLoc = ":stdin:"

  else:
    if state.dockerFileLoc == "":
      let toResolve = joinPath(state.foundcontext, "Dockerfile")
      state.dockerFileLoc = resolvePath(toResolve)

    try:
      withFileStream(state.dockerFileLoc, mode = fmRead, strict = false):
        if stream != nil:
          state.inDockerFile = stream.readAll()
          trace("docker: read Dockerfile at: " & state.dockerFileLoc)
        else:
          error("docker: " & state.foundFileArg & ": Dockerfile not found")
          raise newException(ValueError, "No Dockerfile")

    except:
      dumpExOnDebug()
      error("docker: " & state.foundFileArg & ": Dockerfile not readable")
      raise newException(ValueError, "Read perms")

proc processCmdLine(ctx: DockerInvocation) =
  ## The main docker parse tries to pull out as many flags as it can
  ## to try to keep us from confusing contexts with flag args, etc.
  ##
  ## However, instead of trying to properly put a "correct"
  ## command line back together from that, we run a *second*
  ## parse of the command line that ignores everything *except*
  ## things that we rewrite when we see.
  ##
  ## Right now, we rewrite:
  ##
  ## * Any dockerfile passed. (--file or -f)
  ## * Git context, if any (when context is a git uri)
  ##
  ## Everything else we just ignore, and pass through in place.
  ##
  ## We treat the ones that take args as it they could be added
  ## multiple times, even though only some of them can accept that
  ## (e.g. --tag). But just trying to be conservative; could imagine
  ## multiple values for --output-type for instance.

  let reparse = CommandSpec(maxArgs: high(int), dockerSingleArg: true,
                            unknownFlagsOk: true, noSpace: false)

  reparse.addFlagWithArg("file", ["f", "file"], multi = true,
                         clobberOk = true, optArg = false)

  ctx.newCmdLine = reparse.parse(ctx.originalArgs).args[""]

  if ctx.gitContext != nil:
    ctx.newCmdLine = ctx.gitContext.replaceContextArg(ctx.newCmdLine)

proc addVirtualLabels(ctx: DockerInvocation, chalk: ChalkObj) =
  trace("docker: adding virtual label args via --label flags")
  let labelOpt = getOpt[TableRef[string, string]](chalkConfig, "docker.custom_labels")
  if labelOpt.isSome():
    ctx.newCmdLine.addLabelArgs(labelOpt.get())
  let labelTemplName = get[string](chalkConfig, "docker.label_template")
  if labelTemplName == "":
    return
  let
    labelTemplate = chalkConfig.markTemplates[labelTemplName]
    hostLabelsToAdd = hostInfo.filterByTemplate(labelTemplate)
    artLabelsToAdd  = chalk.collectedData.filterByTemplate(labelTemplate)
  var args: seq[string] = @[]
  args.addLabelArgs(hostLabelsToAdd)
  args.addLabelArgs(artLabelsToAdd)
  if len(args) > 0:
    trace("docker: added " & $(len(args)) & " labels")
    ctx.newCmdLine &= args

proc addLabels(ctx: DockerInvocation, chalk: ChalkObj) =
  trace("docker: adding labels to Dockerfile")
  let labelOpt = getOpt[TableRef[string, string]](chalkConfig, "docker.custom_labels")
  if labelOpt.isSome():
    ctx.addedInstructions.addLabelCmds(labelOpt.get())
  let labelTemplName = get[string](chalkConfig, "docker.label_template")
  if labelTemplName == "":
    return
  let
    labelTemplate    = chalkConfig.markTemplates[labelTemplName]
    hostLabelsToAdd  = hostInfo.filterByTemplate(labelTemplate)
    artLabelsToAdd   = chalk.collectedData.filterByTemplate(labelTemplate)
  var added: seq[string] = @[]
  added.addLabelCmds(hostLabelsToAdd)
  added.addLabelCmds(artLabelsToAdd)
  if len(added) > 0:
    trace("docker: added " & $(len(added)) & " labels")
    ctx.addedInstructions &= added

proc addEnvVars(ctx: DockerInvocation, chalk: ChalkObj) =
  trace("docker: adding environment variables to Dockerfile")
  var
    toAdd: seq[string] = @[]
    value: string
  for k, v in get[TableRef[string, string]](chalkConfig, "docker.additional_env_vars"):
    if not k.isValidEnvVarName():
      warn("docker: ENV var " & k & " NOT added. Environment vars may only have " &
           "Letters (which will be upper-cased), numbers, and underscores.")
      continue
    if v.startsWith("@"):
      try:
        value = chalk.getChalkKey(v)
      except:
        warn("docker: ENV VAR " & k & " NOT added due to:" & getCurrentExceptionMsg())
        continue
    else:
      value = v
    toAdd.addLabelCmd(k.toUpperAscii(), value, prefix = "ENV ")
  if len(toAdd) != 0:
    trace("docker: added " & $(len(toAdd)) & " env vars")
    ctx.addedInstructions &= toAdd

proc getUpdatedDockerfile(ctx: DockerInvocation): string =
  ## add instructions in correct location in Dockerfile
  ## this accounts for section boundaries
  if len(ctx.addedInstructions) == 0:
    return ctx.inDockerFile
  let
    first   = ctx.getFirstDockerSection()
    section = ctx.getTargetDockerSection()
    lines   = ctx.inDockerFile.splitLines()
  var updated: seq[string] = lines[0 ..< first.startLine] & @[""]
  for _, base in ctx.addedPlatform:
    updated &= base & @[""]
  updated &= lines[first.startLine .. section.endLine].join("\n").strip().splitLines() & @[""]
  updated &= ctx.addedInstructions & @[""]
  updated &= lines[section.endLine + 1 .. ^1].join("\n").strip().splitLines()
  return updated.join("\n").strip() & "\n"

proc setDockerFile(ctx: DockerInvocation) =
  # If we're not changing the Docker file, then we add an explicit -f
  # specifying the location. This may not have been specified by the
  # user, but it is good to be explicit.
  if len(ctx.addedInstructions) == 0:
    trace("docker: dockerfile was not modified. using original dockerfile")
    if ctx.dockerFileLoc == ":stdin:":
      ctx.newCmdLine.add("-f")
      ctx.newCmdLine.add("-")
      ctx.newStdIn = ctx.inDockerFile
      return
    else:
      ctx.newCmdLine.add("-f")
      ctx.newCmdLine.add(ctx.dockerFileLoc)
      return

  let dockerFile = ctx.getUpdatedDockerFile()

  if ctx.foundContext != "-":
    trace("docker: passing updated dockerfile via stdin")
    # If context is not over stdin we can safely pass dockerfile via stdin
    ctx.newCmdLine.add("-f")
    ctx.newCmdLine.add("-")
    ctx.newStdIn = dockerFile
  else:
    trace("docker: passing updated dockerfile via temp file")
    # Otherwise, when we have to write out an actual Docker file, we
    # should properly be using a temporary file, because it's a place
    # we're generally guaranteed to be able to write.
    let path = writeNewTempFile(dockerFile)
    info("docker: created temporary Dockerfile at: " & path)
    trace("docker: new docker file:\n" & dockerFile)
    ctx.newCmdLine.add("-f")
    ctx.newCmdLine.add(path)

proc setIidFile(ctx: DockerInvocation) =
  if ctx.foundIidFile == "":
    trace("docker: adding --iidfile flag")
    # ensure file is closed so docker can overwrite it
    ctx.iidFilePath = writeNewTempFile("", suffix = ".iidfile")
    ctx.newCmdLine &= @["--iidfile", ctx.iidFilePath]
  else:
    ctx.iidFilePath = ctx.foundIidFile

proc setMetadataFile(ctx: DockerInvocation) =
  if ctx.foundMetadataFile == "" and hasBuildx():
    trace("docker: adding --metadata-file flag")
    # ensure file is closed so docker can overwrite it
    ctx.metadataFilePath = writeNewTempFile("", suffix = ".metatadata-file")
    ctx.newCmdLine &= @["--metadata-file", ctx.metadataFilePath]
  else:
    ctx.metadataFilePath = ctx.foundMetadataFile

proc readIidFile(ctx: DockerInvocation) =
  ctx.iidFile = tryToLoadFile(ctx.iidFilePath).extractDockerHash()
  trace("docker: --iddfile: " & ctx.iidFile)

proc tryParseMetadataFile(data: string): JsonNode =
  try:
    return parseJson(data)
  except:
    warn("docker: --metadata-file has invalid json: " & getCurrentExceptionMsg())
    return newJObject()

proc readMetadataFile(ctx: DockerInvocation) =
  if ctx.metadataFilePath == "":
    ctx.metadataFile = newJObject()
    return
  var data = tryToLoadFile(ctx.metadataFilePath)
  trace("docker: --metadata-file: " & data)
  if data == "":
    data = "{}"
  ctx.metadataFile = data.tryParseMetadataFile()

proc launchDockerSubscan(ctx:     DockerInvocation,
                         contexts: seq[string]): Box =

  var usableContexts: seq[string]
  for context in contexts:
    if context == "-":
      warn("docker: currently cannot sub-chalk contexts passed via stdin.")
      continue
    if ':' in context:
      warn("docker: cannot sub-chalk remote context: " & context & " (skipping)")
      continue
    try:
      discard context.resolvePath().getFileInfo()
      usableContexts.add(context)
    except:
      warn("docker: cannot find context directory for subscan: " & context)
      continue
  if len(usableContexts) == 0:
    warn("docker: no context sub scanning performed.")
  info("docker: starting a recursive subscan of context directories.")
  result = runChalkSubScan(usableContexts, "insert").report
  trace("docker: subscan complete.")

proc collectBeforeBuild*(chalk: ChalkObj, ctx: DockerInvocation) =
  let dict = chalk.collectedData
  dict.setIfNeeded("DOCKERFILE_PATH",                  ctx.dockerFileLoc)
  dict.setIfNeeded("DOCKER_ADDITIONAL_CONTEXTS",       ctx.foundExtraContexts)
  dict.setIfNeeded("DOCKER_CHALK_ADDED_TO_DOCKERFILE", ctx.addedInstructions)
  dict.setIfNeeded("DOCKER_CONTEXT",                   ctx.foundContext)
  dict.setIfNeeded("DOCKER_FILE",                      ctx.inDockerFile)
  dict.setIfNeeded("DOCKER_LABELS",                    ctx.foundLabels)
  dict.setIfNeeded("DOCKER_PLATFORMS",                 $(ctx.foundPlatforms))
  dict.setIfNeeded("DOCKER_TAGS",                      ctx.foundTags.asRepoTag())
  dict.setIfNeeded("DOCKER_BASE_IMAGE",                $(ctx.getBaseDockerSection.image))
  dict.setIfNeeded("DOCKER_BASE_IMAGE_REPO",           ctx.getBaseDockerSection.image.repo)
  dict.setIfNeeded("DOCKER_BASE_IMAGE_TAG",            ctx.getBaseDockerSection.image.tag)
  dict.setIfNeeded("DOCKER_BASE_IMAGE_DIGEST",         ctx.getBaseDockerSection.image.digest)

proc collectAfterBuild(ctx: DockerInvocation, chalksByPlatform: TableRef[DockerPlatform, ChalkObj]) =
  if dockerImageExists(ctx.iidFile):
    trace("docker: built image is loaded locally")
    # in some cases even with --push, repo digests show up as blank in docker inspect
    # but we might know the digest from the --metadata-file so we normalize to that
    let digest = ctx.metadataFile{"containerimage.digest"}.getStr()
    # image was loaded to docker cache
    for platform, chalk in chalksByPlatform:
      chalk.collectImage(ctx.iidFile, digest = digest)
  elif len(ctx.foundTags) > 0:
    trace("docker: inspecting pushed image from registry")
    # iidfile can be one of in order of precedence:
    # 1. manifest list digest
    # 2. image config digest
    # and so we attempt to get digest id from metadata file first
    let
      digest = ctx.metadataFile{"containerimage.digest"}.getStr(ctx.iidFile)
      names  = parseImages(ctx.metadataFile{"image.name"}.getStr().split(","))
    for platform, chalk in chalksByPlatform:
      let name = ctx.foundTags[0].withDigest(digest)
      chalk.collectImageManifest(name, otherNames = names)
  else:
    # this case in theory should never happen
    # as iid file when present should always be either locally loaded image
    # or pushed to the registry. otherwise iidfile is expected to be empty
    # however docker is full of surprises...
    raise newException(
      ValueError,
      "could not inspect built image " & ctx.iidFile &
      " as there are no found tags for it"
    )

proc dockerBuild*(ctx: DockerInvocation): int =
  ## main function for orchestrating docker build wrapping
  ## this function is rather long - by design
  ## it is reponsible for calling all utility functions
  ## but the full build flow can easily be followed in a single
  ## linear function without a maze of nested function calls
  let
    # this is not the final chalk "artifact" but is just a placeholder
    # to collect necessary metadata for the chalkmark to be inserted in the image
    # however after the image is built all metadata will need to be recolledted,
    # potentially multiple times for multi-platform builds.
    # NOTE this is explicitly not stored on DockerInvocation
    # and is instead explicitly being passed around where necessary
    # to avoid storing transient data in DockerInvocation
    baseChalk = newChalk(
      resourceType = {ResourceImage},
      codec        = getPluginByName("docker"),
      # multi-platform builds should have same chalk id
      chalkId      = ctx.chalkId,
    )
    wrapVirtual    = get[bool](chalkConfig, "virtual_chalk")
    wrapEntrypoint = get[bool](chalkConfig, "docker.wrap_entrypoint")
    dockerSubscan  = get[bool](chalkConfig, "chalk_contained_items")

  trace("docker: processing build CLI args")
  ctx.processGitContext()
  ctx.processDockerFile()
  ctx.processCmdLine()
  ctx.evalAndExtractDockerfile(ctx.getAllBuildArgs())

  forceReportKeys(["_REPO_TAGS", "_REPO_DIGESTS"])
  # force DOCKER_PLATFORM to be included in chalk normalization
  # which is required to compute unique METADATA_* keys
  forceChalkKeys(["DOCKER_PLATFORM"])

  trace("docker: collecting pre-build metadata")
  let contexts = ctx.getAllDockerContexts()
  setContextDirectories(contexts)
  initCollection()
  if dockerSubscan:
    info("docker: starting subscan of context directories.")
    let
      subscanBox = ctx.launchDockerSubscan(contexts)
      unpacked   = unpack[seq[Box]](subscanBox)
    baseChalk.collectedData.setIfNeeded("EMBEDDED_CHALK", unpacked)
    info("docker: context directories subscan finished.")

  trace("docker: preparing chalk marks for build")
  var oneChalk       = baseChalk
  let
    platforms        = ctx.getAllPlatforms()
    chalksByPlatform = baseChalk.copyPerPlatform(platforms)
  # chalk time artifact info determines metadata id/etc
  # so has to be done by platform
  for _, chalk in chalksByPlatform:
    chalk.collectChalkTimeArtifactInfo()
    oneChalk = chalk

  if wrapVirtual:
    trace("docker: preparing virtual build")
    if wrapEntrypoint:
      warn("docker: cannot wrap entry point in virtual chalking mode.")
    ctx.addVirtualLabels(oneChalk)

  else:
    trace("docker: wrapping regular build")
    ctx.addLabels(oneChalk)
    ctx.addEnvVars(oneChalk)
    try:
      # this ensures all platforms have same USER
      let user = ctx.getCommonTargetUser(platforms)
      if wrapEntrypoint:
        trace("docker: wrapping ENTRYPOINT")
        try:
          ctx.withAtomicAdds():
            let
              # this also ensures all platfoms have the same entrypoints
              entrypoints = ctx.getCommonTargetEntrypoints(platforms)
              binaries    = ctx.findAllPlatformsBinaries(platforms)
            ctx.rewriteEntryPoint(entrypoints, binaries, user)
        except:
          dumpExOnDebug()
          warn("docker: cannot wrap ENTRYPOINT due to: " & getCurrentExceptionMsg())
      trace("docker: injecting chalk mark (/chalk.json) to build")
      try:
        ctx.withAtomicAdds():
          for platform, chalk in chalksByPlatform:
            ctx.makeTextAvailableToDocker(
              text       = chalk.getChalkMarkAsStr(),
              newPath    = "/chalk.json",
              user       = user,
              move       = true,
              chmod      = "0444",
              byPlatform = ctx.isMultiPlatform(),
              platform   = platform,
            )
      except:
        dumpExOnDebug()
        warn("docker: Cannot inject chalk mark (/chalk.json) due to: " & getCurrentExceptionMsg())
    except:
      dumpExOnDebug()
      warn("docker: Cannot wrap docker image due to: " & getCurrentExceptionMsg())

  # collecting build information has to be after all wrapping
  # as some chalk keys are record how docker build was mutated
  # such as what instructions were added to dockerfile
  trace("docker: collecting pre-build metadata into chalkmark")
  for platform, chalk in chalksByPlatform:
    chalk.collectBeforeBuild(ctx)

  ctx.setDockerFile()
  ctx.setIidFile()
  ctx.setMetadataFile()

  result = ctx.runMungedDockerInvocation()
  if result != 0:
    raise newException(
      ValueError,
      "wrapped docker build exited with " & $result
    )

  ctx.readIidFile()
  ctx.readMetadataFile()

  if ctx.iidFile == "":
    warn(
      "docker: build did not produce image for chalk to inspect. " &
      "Did you forget to use either --load or --push?"
    )
    return

  trace("docker: collecting built image metadata")
  try:
    ctx.collectAfterBuild(chalksByPlatform)
  except:
    warn("docker: " & getCurrentExceptionMsg())
    return

  trace("docker: collecting post-build runtime data")
  for _, chalk in chalksByPlatform:
    chalk.addToAllChalks()
    chalk.collectRunTimeArtifactInfo()
    chalk.marked = true
  collectRunTimeHostInfo()

  if wrapVirtual and result == 0:
    for platform, chalk in chalksByPlatform:
      publish("virtual", chalk.getChalkMarkAsStr())
