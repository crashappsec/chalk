import posix, osproc, unicode, ../config, ../selfextract, ../collect,
       ../reporting, ../chalkjson, ../plugin_api, ../plugins/codecDocker,
       cmd_defaults

template dockerPassthroughExec() {.dirty.} =
  let exe = findDockerPath().getOrElse("")
  if exe != "":
    trace("Running docker by calling: " & exe & " " & myargs.join(" "))
    let
      subp = startProcess(exe, args = myargs, options = {poParentStreams})
      code = subp.waitForExit()
    if code != 0:
      trace("Docker exited with code: " & $(code))
      opFailed = true
  else:
    opFailed = true

# Files get opened when the subscription happens, not the first time a
# write is attempted. If this gets called, it's because the mark file
# was opened, but not written to.
#
# So if we see it, AND it's zero bytes in length, we try to clean it up,
# but if we can't, no harm, no foul.
#
# Note that we're not really checking to see whether the sink is actually
# subscribed to the 'virtual' topic right now!
proc virtualMarkCleanup() =
  if "virtual_chalk_log" notin chalkConfig.sinkConfs:
    return

  let conf = chalkConfig.sinkConfs["virtual_chalk_log"]

  if conf.enabled == false:                    return
  if conf.sink notin ["file", "rotating_log"]: return

  try:
    removeFile(get[string](conf.`@@attrscope@@`, "filename"))
    trace("Removed empty virtual chalk file.");
  except:
    discard

{.warning[CStringConv]: off.}
template parseDockerCmdline*(): (string, seq[string],
                             OrderedTable[string, FlagSpec])  =
  con4mRuntime.addStartGetopts("docker.getopts", args = getArgs()).run()
  (con4mRuntime.getCommand(), con4mRuntime.getArgs(), con4mRuntime.getFlags())

proc runCmdDocker*() {.noreturn.} =
  var
    opFailed     = false
    reExecDocker = false
    chalk: ChalkObj

  let
    (cmd, args, flags) = parseDockerCmdline() # in config.nim
    codec              = Codec(getPluginByName("docker"))

  var
    myargs             = getArgs() # The original command lines

  try:
    case cmd
    of "build":
      setCommandName("build")
      initCollection()

      if len(args) == 0:
        trace("No arguments to 'docker build'; passing through to docker")
        opFailed     = true
        reExecDocker = true
      else:
        chalk = newChalk(FileStream(nil), resolvePath(args[^1]))
        chalk.myCodec = codec
        chalk.extract = ChalkDict() # Treat this as marked.
        addToAllChalks(chalk)
        # Let the docker codec deal w/ env vars, flags and docker files.
        if extractDockerInfo(chalk, flags, args[^1]):
          trace("Successful parsing of docker cmdline and dockerfile")
          # Then, let any plugins run to collect data.
          chalk.collectChalkInfo()
          # Now, have the codec write out the chalk mark.
          let toWrite    = chalk.getChalkMarkAsStr()

          if chalkConfig.getVirtualChalk():
            let cache = DockerInfoCache(chalk.cache)
            myargs = myargs & @["-t=" & cache.ourTag]

            dockerPassthroughExec()
            if opFailed:
              # Since docker didn't fail because of us, we don't run it again.
              # We don't have to do anything to make that happen, as
              # reExecDocker is already false.
              #
              # Similarly, if we output an error here, it may look like it's
              # our fault, so better to be silent unless they explicitly
              # run with --trace.
              trace("'docker build' failed for a Dockerfile that we didn't " &
                    "modify, so we won't rerun it.")
              virtualMarkCleanup()
            elif not runInspectOnImage(exe, chalk):
              # This might have been because of us, so play it safe and re-exec
              error("Docker inspect failed")
              opFailed     = true
              reExecDocker = true
              virtualMarkCleanup()
            else:
              publish("virtual", toWrite)
              info(chalk.fullPath & ": virtual chalk created.")
              chalk.collectRunTimeChalkInfo()
          else:
            try:
              chalk.writeChalkMark(toWrite)
              virtualMarkCleanup()
              #% INTERNAL
              var wrap = chalkConfig.dockerConfig.getWrapEntryPoint()
              if wrap:
                let selfChalk = getSelfExtraction().getOrElse(nil)
                if selfChalk == nil or not canSelfInject:
                  error("Platform does not support entry point rewriting")
                else:
                  selfChalk.collectChalkInfo()
                  chalk.prepEntryPointBinary(selfChalk)
                  setCommandName("load")
                  let binaryChalkMark = selfChalk.getChalkMarkAsStr()
                  setCommandName("build")
                  chalk.writeEntryPointBinary(selfChalk, binaryChalkMark)
              #% END
              # We pass the full getArgs() in, as it will get re-parsed to
              # make sure all original flags stay in their order.
              if chalk.buildContainer(flags, getArgs()):
                info(chalk.fullPath & ": container successfully chalked")
                chalk.collectRunTimeChalkInfo()
              else:
                error(chalk.fullPath & ": chalking the container FAILED. " &
                      "Rebuilding without chalking.")
                opFailed     = true
                reExecDocker = true
            except:
              opFailed     = true
              reExecDocker = true
              error(getCurrentExceptionMsg())
              error("Above occurred when runnning docker command: " &
                myargs.join(" "))
              dumpExOnDebug()
        else:
          # In this branch, we never actually tried to exec docker.
          info("Failed to extract docker info.  Calling docker directly.")
          opFailed     = true
          reExecDocker = true
      doReporting(if opFailed: "fail" else: "report")
    of "push":
      setCommandName("push")
      initCollection()
      dockerPassthroughExec()
      if not opFailed:
        let
          passedTag  = myargs[^1]
          args       = ["inspect", passedTag]
          inspectOut = execProcess(exe, args = args, options = {})
          items      = parseJson(inspectOut).getElems()

        if len(items) == 0:
          error("chalk: Docker inspect didn't see image after 'docker push'")
        else:
          processPushInfo(items, passedTag)
          doReporting()
      else:
        # The push *did* fail, but we don't need to re-run docker, because
        # we didn't munge the command line; it was going to fail anyway.
        reExecDocker = false
    else:
      initCollection()
      reExecDocker = true
      trace("Unhandled docker command: " & myargs.join(" "))
      if chalkConfig.dockerConfig.getReportUnwrappedCommands():
        doReporting("fail")
  except:
    error(getCurrentExceptionMsg())
    error("Above occurred when runnning docker command: " & myargs.join(" "))
    dumpExOnDebug()
    reExecDocker = true
    doReporting("fail")
  finally:
    if chalk != nil:
      chalk.cleanupTmpFiles()

  showConfig()

  if not reExecDocker:
    quit(if opFailed: 1 else: 0)

  # This is the fall-back exec for docker when there's any kind of failure.
  let exeOpt = findDockerPath()
  if exeOpt.isSome():
    let exe    = exeOpt.get()
    var toExec = getArgs()

    trace("Execing docker: " & exe & " " & toExec.join(" "))
    toExec = @[exe] & toExec
    discard execvp(exe, allocCStringArray(toExec))
    error("Exec of '" & exe & "' failed.")
  else:
    error("Could not find 'docker'.")
  quit(1)

proc getContainerIds(dockerExe: string): seq[string] =
  let
    cmd = [dockerExe, "ps", "--quiet"].join(" ")
    (idlist, errCode) = execCmdEx(cmd, options = {})
  if errCode == 0:
    return unicode.strip(idList).split("\n")

proc runCmdExtractContainers*(images: seq[string]) =
  let
    dockerExe      = findDockerPath().getOrElse("")
    chalkLoc       = chalkConfig.dockerConfig.getChalkFileLocation()
    dockerCodec    = Codec(getPluginByName("docker"))
    reportUnmarked = chalkConfig.dockerConfig.getReportUnmarked()

  var
    toCheck    = images
    oneExtract = false
    chalk: ChalkObj

  initCollection()

  if len(images) == 0 or "all" in images:
    toCheck = getContainerIds(dockerExe)

  for item in toCheck:
    var extracted = false

    # Typically will read, "docker cp 1094ddfde117:/chalk.json -"
    # Where the - sends the result to stdout
    let cmdline = [dockerExe, "cp", item & ":" & chalkLoc, "-"].join(" ")
    let (mark, errCode) = execCmdEx(cmdline, options = {poStdErrToStdOut})

    if errCode != 0:
      if mark.contains("No such container"):
        error("Container " & item & " not found")
        continue # Don't create a chalk object if there's no container.
      elif mark.contains("Could not find the file"):
        warn("Container " & item & " is unmarked.")
      else:
        error("Error when extracting from container " & item & ": " & mark)
        # Hopefully this doesn't happen?  Let's try to report anyway.
    else:
      try:
        let extract = extractOneChalkJson(newStringStream(mark), item)

        extracted  = true
        oneExtract = true
        chalk      = ChalkObj(collectedData: ChalkDict(),
                              extract:       extract,
                              marked:        true,
                              myCodec:       dockerCodec)
      except:
        error("In container with id " & item & ": Invalid chalk mark")

    if not extracted:
      if reportUnmarked:
        chalk = ChalkObj(collectedData: ChalkDict(),
                         extract:       nil,
                         marked:        false,
                         myCodec:       dockerCodec)
      else:
        addUnmarked(item)

    chalk.addToAllChalks()

    let
      cache         = DockerInfoCache(container: true)
      (output, err) = execCmdEx([dockerExe,"inspect", item].join(" "),
                                options = {})
    var
      jsonElems: seq[JsonNode]

    if err != 0:
      error("Could not run 'docker inspect " & item & "'")
      continue
    try:
      jsonElems = unicode.strip(output).parseJson().getElems()
    except:
      error("Did not get valid JSon from 'docker inspect " & item & "'")
      continue

    if len(jsonElems) != 0:
      cache.inspectOut = jsonElems[0]

    chalk.cache = cache
    chalk.collectRunTimeChalkInfo()
    chalk.myCodec.cleanup(chalk)

  if not oneExtract: warn("No chalk marks extracted")
  doReporting()
