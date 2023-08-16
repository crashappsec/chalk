import config

proc extractOpInfo(state: DockerInvocation) =
  case state.cmd
  of "build":
    state.cmdBuild = true
    if "push" in state.flags:
      state.cmdPush = true
    elif "output" in state.flags:
      let vals = unpack[seq[string]](state.flags["output"].getValue())
      for item in vals:
        if "type=registry" in item:
          state.cmdPush = true
          break
  of "push":
    state.cmdPush = true

proc addBackAllOutputFlags*(state: DockerInvocation) =
  # Here, we know 'push' isn't in the list.
  if "load" in state.flags:
    state.newCmdLine.add("--load")
  if "output" notin state.flags:
    return
  for item in unpack[seq[string]](state.flags["output"].getValue()):
    state.newCmdLine.add("--output=" & item)

proc addBackOtherOutputFlags*(state: DockerInvocation) =
  # If this was a buildx build command that had a push in there too,
  # we add a --load for good measure.
  if "output" in state.flags or "load" in state.flags or "push" in state.flags:
    state.newCmdLine.add("--load")
  if "output" notin state.flags:
    return
  for item in unpack[seq[string]](state.flags["output"].getValue()):
    if "registry" notin item:
      state.newCmdLine.add("--output=" & item)

proc extractPrivs(state: DockerInvocation) =
  if "allow" in state.flags:
    state.privs = unpack[seq[string]](state.flags["allow"].getValue())

proc extractTarget(state: DockerInvocation) =
  if "target" in state.flags:
    let targets = unpack[seq[string]](state.flags["target"].getValue())
    state.targetBuildStage = targets[0]

proc extractTags(state: DockerInvocation) =
  if "tag" in state.flags:
    state.foundTags = unpack[seq[string]](state.flags["tag"].getValue())
    if len(state.foundTags) > 0:
      state.prefTag = state.foundTags[0]

proc extractPlatform(state: DockerInvocation) =
  if "platform" in state.flags:
    let platforms = unpack[seq[string]](state.flags["platform"].getValue())
    if len(platforms) > 1:
      # We don't want to try to wrap this right now.
      state.foundPlatform = "multi-arch"
    else:
      state.foundPlatform = platforms[0]


proc extractBuildArgs(state: DockerInvocation) =
  if "build-arg" in state.flags:
    let items = unpack[seq[string]](state.flags["build-arg"].getValue())

    for item in items:
      let ix = item.find('=')
      if ix == -1:
        state.buildArgs[item] = ""
      else:
        if len(item) == ix + 1:
          state.buildArgs[item[0 ..< ix]] = ""
        else:
          state.buildArgs[item[0 ..< ix]] = item[ix + 1 .. ^1]

proc getDockerFileLoc*(state: DockerInvocation): string =
  if state.inDockerFile != "":
    return state.dockerFileLoc
  else:
    state.dockerFileLoc = resolvePath(state.foundContext).joinPath("Dockerfile")
    return state.dockerFileLoc

proc extractDockerFileFlag(state: DockerInvocation) =
  # Does not resolve the path.
  if "file" in state.flags:
    let files = unpack[seq[string]](state.flags["file"].getValue())
    state.foundFileArg = files[0]

    if state.foundFileArg == "-":
      state.dockerFileLoc = ":stdin:"
    else:
      state.dockerFileLoc = resolvePath(state.foundFileArg)

proc loadDockerFile*(state: DockerInvocation) =
  if state.dockerFileLoc == "":
    let toResolve = joinPath(state.foundcontext, "Dockerfile")
    state.dockerFileLoc = resolvePath(toResolve)

  if state.dockerFileLoc[0] == ':':
    state.inDockerFile = stdin.readAll()
    trace("Read Dockerfile from stdin")
  else:
    let s = newFileStream(state.dockerFileLoc)

    try:
      if s != nil:
        state.inDockerFile = s.readAll()
        s.close()
        trace("Read Dockerfile at: " & state.dockerFileLoc)
      else:
        error(state.foundFileArg & ": Dockerfile not found")
        raise newException(ValueError, "No Dockerfile")

    except:
      dumpExOnDebug()
      error(state.foundFileArg & ": Dockerfile not readable")
      raise newException(ValueError, "Read perms")


proc extractLabels(state: DockerInvocation) =
  if "label" in state.flags:
    let rawLabels = unpack[seq[string]](state.flags["label"].getValue())
    for item in rawLabels:
      let arr = item.split("=")
      state.foundLabels[arr[0]] = arr[^1]

proc extractExtraContexts(state: DockerInvocation) =
  if "build-contexts" in state.flags:
    let raw = unpack[seq[string]](state.flags["build-contents"].getValue())

    for item in raw:
      if len(item) == 0:
        continue
      let ix = item.find('=')
      if ix == -1 or ix == len(item) - 1:
        continue
      state.otherContexts[item[0 ..< ix]] = item[ix + 1 .. ^1]

proc setPushReference(state: DockerInvocation) =
  if len(state.processedArgs) == 0:
    return

  state.prefTag = state.processedArgs[0]

proc extractPushCmdTags(state: DockerInvocation) =
  if "all-tags" in state.flags:
    state.pushAllTags = true
  else:
    state.extractTags()

proc extractCmdlineBuildContext*(state: DockerInvocation) =
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


  if len(state.processedArgs) == 1:
    state.foundContext = state.processedArgs[0]
    return

  var
    prevArgWasntFlag = true
    lastGoodArg      = ""

  for item in state.processedArgs:
      if len(item) != 0 and item[0] == '-':
        prevArgWasntFlag = false
        trace("Chalk doesn't know the docker flag: " & item)
        continue
      elif prevArgWasntFlag:
        state.foundContext = item
        return
      lastGoodArg      = item
      prevArgWasntFlag = true

  state.foundContext = lastGoodArg


proc stripFlagsWeRewrite*(ctx: DockerInvocation) =
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
  ## 1. Any dockerfile passed. (--file or -f)
  ## 2. Any --push flag (we generate a separate push command).
  ## 3. Any --outpute fields, as --push is an alias for
  ##    --output=type=repository.
  ## 4. The build stage set via --target
  ##
  ## Everything else we just ignore, and pass through in place.
  ##
  ## We treat the ones that take args as it they could be added
  ## multiple times, even though I don't think you can for any
  ## of them. But just trying to be conservative; could imagine
  ## multiple values for --output-type for instance.

  let reparse = CommandSpec(maxArgs: high(int), dockerSingleArg: true,
                            unknownFlagsOk: true, noSpace: false)

  reparse.addYesNoFlag("push", ["push"], [])
  reparse.addYesNoFlag("load", ["load"], [])
  reparse.addFlagWithArg("file", ["f", "file"], true, true, optArg = false)
  reparse.addFlagWithArg("target", [], true, true, optArg = false)
  reparse.addFlagWithArg("output", [], true, true, optArg = false)


  ctx.newCmdLine = reparse.parse(ctx.originalArgs).args[""]

proc processDockerCmdLine*(args: seq[string]): DockerInvocation =
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

  new result

  con4mRuntime.addStartGetopts("docker.getopts", args = args).run()

  result.originalArgs  = args
  result.foundLabels   = OrderedTableRef[string, string]()
  result.otherContexts = OrderedTableRef[string, string]()
  result.cmd           = con4mRuntime.getCommand()
  result.flags         = con4mRuntime.getFlags()
  result.processedArgs = con4mRuntime.getArgs()

  result.extractOpInfo()

  case result.cmd
  of "build":
    result.extractBuildArgs()
    result.extractDockerFileFlag()
    result.extractLabels()
    result.extractExtraContexts()
    result.extractPlatform()
    result.extractTags()
    result.extractTarget()
    result.extractPrivs()
  of "push":
    result.setPushReference()
    result.extractPushCmdTags()
  of "image":
    # docker image tag rhel-httpd:latest
    #        registry-host:5000/myadmin/rhel-httpd:latest
    # docker image push registry-host:5000/myadmin/rhel-httpd:latest
    discard
  of "container":
    # docker container commit c16378f943fe rhel-httpd:latest
    discard
  else:
    return
