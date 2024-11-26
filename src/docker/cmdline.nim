##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This module deals with extracting information we need from the
## docker command line. The command line is automatically parsed by
## con4m when we call processDockerCmdLine (the spec it uses to parse
## is in configs/dockercmd.c4m), so we really just need to look at
## the command and flag info returned.

import ".."/[config]
import "."/[ids]

proc extractBuildx(ctx: DockerInvocation) =
  ctx.foundBuildx = ctx.cmdName.startsWith("buildx.")

proc extractBuilder(ctx: DockerInvocation) =
  if "builder" in ctx.processedFlags:
    let targets = unpack[seq[string]](ctx.processedFlags["builder"].getValue())
    ctx.foundBuilder = targets[0]

proc extractIidFile(ctx: DockerInvocation) =
  if "iidfile" in ctx.processedFlags:
    let targets = unpack[seq[string]](ctx.processedFlags["iidfile"].getValue())
    ctx.foundIidFile = targets[0]

proc extractMetadataFile(ctx: DockerInvocation) =
  if "metadata-file" in ctx.processedFlags:
    let targets = unpack[seq[string]](ctx.processedFlags["metadata-file"].getValue())
    ctx.foundMetadataFile = targets[0]

proc extractTarget(ctx: DockerInvocation) =
  if "target" in ctx.processedFlags:
    let targets = unpack[seq[string]](ctx.processedFlags["target"].getValue())
    ctx.foundTarget = targets[0]

proc extractTags(ctx: DockerInvocation) =
  ctx.foundTags = @[]
  if "tag" in ctx.processedFlags:
    ctx.foundTags = parseImages(unpack[seq[string]](ctx.processedFlags["tag"].getValue()))

proc extractPlatforms*(ctx: DockerInvocation) =
  var platforms: seq[string] = @[]
  if "platform" in ctx.processedFlags:
    platforms = unpack[seq[string]](ctx.processedFlags["platform"].getValue())
  elif existsEnv("DOCKER_DEFAULT_PLATFORM"):
    platforms = getEnv("DOCKER_DEFAULT_PLATFORM").split(",")
  ctx.foundPlatforms = @[]
  for platform in platforms:
    ctx.foundPlatforms.add(parseDockerPlatform(platform))

proc extractBuildArgs(ctx: DockerInvocation) =
  ctx.foundBuildArgs = newTable[string, string]()
  if "build-arg" in ctx.processedFlags:
    let items = unpack[seq[string]](ctx.processedFlags["build-arg"].getValue())
    for item in items:
      let ix = item.find('=')
      if ix == -1:
        ctx.foundBuildArgs[item] = ""
      else:
        if len(item) == ix + 1:
          ctx.foundBuildArgs[item[0 ..< ix]] = ""
        else:
          ctx.foundBuildArgs[item[0 ..< ix]] = item[ix + 1 .. ^1]

proc extractDockerFile(ctx: DockerInvocation) =
  if "file" in ctx.processedFlags:
    let files = unpack[seq[string]](ctx.processedFlags["file"].getValue())
    ctx.foundFileArg = files[0]
    if ctx.foundFileArg == "-":
      ctx.dockerFileLoc = ":stdin:"
    else:
      ctx.dockerFileLoc = resolvePath(ctx.foundFileArg)

proc extractLabels(ctx: DockerInvocation) =
  ctx.foundLabels = newOrderedTable[string, string]()
  if "label" in ctx.processedFlags:
    let rawLabels = unpack[seq[string]](ctx.processedFlags["label"].getValue())
    for item in rawLabels:
      let arr = item.split("=")
      ctx.foundLabels[arr[0]] = arr[^1]

proc extractAnnotations(ctx: DockerInvocation) =
  ctx.foundAnnotations = newOrderedTable[string, string]()
  if "annotation" in ctx.processedFlags:
    let rawAnnotations = unpack[seq[string]](ctx.processedFlags["annotation"].getValue())
    for item in rawAnnotations:
      let arr = item.split("=")
      ctx.foundAnnotations[arr[0]] = arr[^1]

proc extractExtraContexts(ctx: DockerInvocation) =
  ctx.foundExtraContexts = newOrderedTable[string, string]()
  if "build-contexts" in ctx.processedFlags:
    let raw = unpack[seq[string]](ctx.processedFlags["build-contents"].getValue())
    for item in raw:
      if len(item) == 0:
        continue
      let ix = item.find('=')
      if ix == -1 or ix == len(item) - 1:
        continue
      ctx.foundExtraContexts[item[0 ..< ix]] = item[ix + 1 .. ^1]

proc extractImage(ctx: DockerInvocation) =
  if len(ctx.processedArgs) == 0:
    return
  ctx.foundImage = ctx.processedArgs[0]

proc extractAllTags(ctx: DockerInvocation) =
  if "all-tags" in ctx.processedFlags:
    ctx.foundAllTags = true

proc extractSecrets(ctx: DockerInvocation) =
  ctx.foundSecrets = newTable[string, DockerSecret]()
  var
    id = ""
    src = ""
  # secrets are passed as:
  # --secret id=<id>,src=<src>
  # however the argument parsing splits the id/src
  # therefore we need to combine them back
  # however as order might not be guaranteed
  # we try our best to group them when both
  # values have been encountered
  if "secret" in ctx.processedFlags:
    for kv in unpack[seq[string]](ctx.processedFlags["secret"].getValue()):
      let
        parts = kv.split("=", maxsplit = 1)
        name  = parts[0]
        value = parts[1]
      case name:
        of "id":
          id = value
        of "src":
          src = value
      if id != "" and src != "":
        ctx.foundSecrets[id] = DockerSecret(id: id, src: src)
        id = ""
        src = ""

proc extractContext(ctx: DockerInvocation) =
  # Con4m "ignoring unknown flags" jams them into the command line.
  # We try to spec every flag, but there may be new flags, or
  # undocumented flags. Or, the arguments might change for existing
  # flags.
  #
  # When we want to get the one context directory, it's supposed to be
  # the only actual argument on the command line. So we need to try to
  # clean up those unknown flags.
  #
  # If there is only one item, then it must be our context.
  #
  # If there are more, we won't know what flags take args and which
  # ones don't.  So, we'll scan through to see if there's an argument
  # that doesn't have a dash, where there is also no dashed argument
  # preceding it.
  #
  # If we find such a thing, it's the context, unless we removed some
  # flag thinking it didn't take args, when it did (which would be a
  # bug).
  #
  # If we find no such argument anywhere, then we assume that, as
  # would be convention, it's the last argument that didn't have a "--".
  #
  # And if we don't find that... ugh.  Return the empty string I guess.
  if len(ctx.processedArgs) == 1:
    ctx.foundContext = ctx.processedArgs[0]
    return

  var
    prevArgWasntFlag = true
    lastGoodArg      = ""

  for item in ctx.processedArgs:
      if len(item) != 0 and item[0] == '-':
        prevArgWasntFlag = false
        trace("docker: Chalk doesn't know the docker flag: " & item)
        continue
      elif prevArgWasntFlag:
        ctx.foundContext = item
        return
      lastGoodArg      = item
      prevArgWasntFlag = true

  ctx.foundContext = lastGoodArg

proc initDockerInvocation*(originalArgs: seq[string]): DockerInvocation =
  ## This does the initial command line parsing, caching the fields we
  ## look at into the DockerInvocation object so that callers don't
  ## have to care about how con4m stores it, etc.

  ## Here, we've already set up a liberal parse in our con4m
  ## configuration (configs/dockercmd.c4m). In the config,
  ## the info we need for parsing is all available via attribute
  ## access, all under `docker.getopts.*`

  ## So, all we need to do here is ask the con4m runtime to call
  ## our getopts parsing using that specification, which will
  ## run the parse and then allow us to extract the subcommand,
  ## flags and remaining arguments.

  try:
    con4mRuntime.addStartGetopts("docker.getopts", args = originalArgs).run()
  except:
    discard

  let
    cmdName =
      try:
        con4mRuntime.getCommand()
      except:
        ""
    cmd =
      case cmdName
      of "buildx.build", "build":
        DockerCmd.build
      of "push":
        DockerCmd.push
      else:
        DockerCmd.other
    flags =
      try:
        con4mRuntime.getFlags()
      except:
        initOrderedTable[string, FlagSpec]()
    args =
      try:
        con4mRuntime.getArgs()
      except:
        @[]

  # this sets minimal fields required to execute fallback behavior
  # the rest of the fields are set in another function to isolate
  # any possible exceptions
  return DockerInvocation(
    chalkId:        dockerGenerateChalkId(),
    originalArgs:   originalArgs,
    originalStdIn:  "", # populated if stdin is read anywhere
    cmdName:        cmdName,
    cmd:            cmd,
    processedFlags: flags,
    processedArgs:  args,
  )

proc extractDockerCommand*(self: DockerInvocation): DockerCmd =
  result = self.cmd
  case self.cmd
  of DockerCmd.build:
    self.extractBuildx()
    self.extractBuilder()
    self.extractIidFile()
    self.extractMetadataFile()
    self.extractDockerFile()
    self.extractContext()
    self.extractBuildArgs()
    self.extractTarget()
    self.extractLabels()
    self.extractAnnotations()
    self.extractExtraContexts()
    self.extractPlatforms()
    self.extractTags()
    self.extractSecrets()
    # set any other non-automatically initialized attributes to avoid segfaults
    self.addedPlatform = newOrderedTable[string, seq[string]]()
  of DockerCmd.push:
    self.extractImage()
    self.extractAllTags()
  else:
    discard
