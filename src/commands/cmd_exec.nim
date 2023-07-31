import posix, ../config, ../collect, ../util, ../reporting, ../chalkjson, ../plugins/codecDocker

when hostOs == "macosx":
  proc proc_pidpath(pid: Pid, pathbuf: pointer, len: uint32): cint
    {.cdecl, header: "<libproc.h>", importc.}

const PATH_MAX = 4096 # PROC_PIDPATHINFO_MAXSIZE on mac

proc doExecCollection(allOpts: seq[string], pid: Pid): Option[ChalkObj] =
  # First, check the chalk file location, and if there's one there, then create
  # a chalk object.
  #
  # If there's no such chalk mark, then we just report based on the
  # exe.
  #
  # Note that if we can't find the process path by PID, we assume it's
  # allOpts[0] for the moment.

  var
    info:  Stat
    chalk: ChalkObj
    chalkPath = chalkConfig.dockerConfig.getChalkFileLocation()

  trace("Looking for a chalk file at: " & chalkPath)

  if stat(cstring(chalkPath), info) == 0:
    info("Found chalk mark in " & chalkPath)

    let
      cidOpt = getContainerName()
      cid    = cidOpt.getOrElse("<<in-container>")

    var  stream   = newFileStream(chalkPath)
    chalk         = newChalk(stream, cid)
    chalk.extract = stream.extractOneChalkJson(cid)
    chalk.myCodec = Codec(getPluginByName("docker"))
    chalk.pid     = some(pid)

    # Denote to the codec that we're running.
    chalk.myCodec.runtime = true
    # Don't let system try to call resolvePath when setting the artifact path.
    chalk.noResolvePath   = true

    result = some(chalk)

    chalk.addToAllChalks()

  else:
    trace("Could not find a container chalk mark at " & chalkPath)

    var
      n:        array[PATH_MAX, char]
      exe1path: string = ""

    when hostOs == "macosx":
      if proc_pidpath(pid, addr n[0], PATH_MAX) > 0:
        exe1path =  $(cast[cstring](addr n[0]))
    elif hostOs == "linux":
        let procPath = "/proc/" & $(pid) & "/exe"
        if readlink(cstring(procPath),
                    cast[cstring](addr n[0]), PATH_MAX) != -1:
          exe1path = $(cast[cstring](addr n[0]))

    if exe1path == "":
      exe1path = allOpts[0]

    # This will only yield at most one result, since item is a file
    # not a dir.  But, we don't want to trigger the post-chalk
    # collection, as it happens when we return from this function
    # (since the docker path doesn't use the iterator).
    #
    # Thus, we break.
    #
    # artifacts() does add to allChalks, which is why we don't do that
    # in this path.


    for item in artifacts(@[exe1path]):
      chalk = item
      break

    if chalk == nil:
      # If we got here, the executable is unmarked.  It won't
      # have a CHALK_ID.
      #
      # Unfortunately, we haven't found a codec either.  On a Linux
      # box this might be because we're in a container, but there
      # was no mark found.
      #
      # On an apple box, we might not be able to see the parent exe.
      #
      # For now, we assume we're running in a container just because
      # we won't try file system IO.

      chalk = newChalk(newFileStream(exe1path), exe1path)
      chalk.addToAllChalks()
      chalk.myCodec = Codec(getPluginByName("docker"))

    result = some(chalk)

    chalk.pid = some(pid)

proc runCmdExec*(args: seq[string]) =
  when not defined(posix):
    error("'exec' command not supported on this platform.")
    quit(1)


  let
    execConfig = chalkConfig.execConfig
    cmdName    = execConfig.getCommandName()
    cmdPath    = execConfig.getSearchPath()
    defaults   = execConfig.getDefaultArgs()
    appendArgs = execConfig.getAppendCommandLineArgs()
    overrideOk = execConfig.getOverrideOk()
    usePath    = execConfig.getUsePath()
    pct        = execConfig.getReportingProbability()
    allOpts    = findAllExePaths(cmdName, cmdPath, usePath)
    ppid       = getpid()   # Get the current pid before we fork.


  if cmdName == "":
    error("This chalk instance has no configured process to exec.")
    error("At the command line, you can pass --exec-command-name to " &
      "set the program name (PATH is searched).")
    error("Add extra directories to search with --exec-search-path.")
    error("In a config file, set exec.command_name and/or exec.search_path")
    quit(1)

  if len(allOpts) == 0:
    error("No executable named '" & cmdName & "' found in your path.")
    quit(1)

  var argsToPass = defaults

  if appendArgs:
    argsToPass &= args
  elif len(args) != 0 and not overrideOk:
    error("Cannot override default arguments on the command line.")
    quit(1)
  elif len(args) != 0:
    argsToPass = args

  if pct != 100:
    let
      inRange = pct/100
      randVal = randInt() / high(int)

    if randVal > inRange:
      handleExec(allOpts, argsToPass)

  let pid  = fork()

  if execConfig.getChalkAsParent():
    if pid == 0:
      handleExec(allOpts, argsToPass)
    else:
      trace("Chalk is parent process.")
      initCollection()
      let chalkOpt = doExecCollection(allOpts, pid)
      if chalkOpt.isSome():
        chalkOpt.get().collectRunTimeChalkInfo()
      doReporting()
      trace("Waiting for spawned process to exit.")
      var stat_loc: cint
      discard waitpid(pid, stat_loc, 0)
      let pid_exit = WEXITSTATUS(stat_loc)
      quit(pid_exit)
  else:
    if pid != 0:
      handleExec(allOpts, argsToPass)
    else:
      trace("Chalk is child process.")
      initCollection()
      trace("Host collection finished.")
      let chalkOpt = doExecCollection(allOpts, ppid)
      discard setpgid(0, 0) # Detach from the process group.
      # On some platforms we don't support
      if chalkOpt.isSome():
        chalkOpt.get().collectRunTimeChalkInfo()

      doReporting()