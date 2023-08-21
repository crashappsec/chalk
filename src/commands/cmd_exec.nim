## The `chalk exec` command.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import posix, ../config, ../collect, ../util, ../reporting, ../chalkjson,
       ../plugin_api

when hostOs == "macosx":
  proc proc_pidpath(pid: Pid, pathbuf: pointer, len: uint32): cint
    {.cdecl, header: "<libproc.h>", importc.}

const
  PATH_MAX = 4096 # PROC_PIDPATHINFO_MAXSIZE on mac

proc doExecCollection(allOpts: seq[string], pid: Pid): Option[ChalkObj] =
  # First, check the chalk file location, and if there's one there, then create
  # a chalk object.
  #
  # If there's no such chalk mark, then we just report based on the
  # exe.
  #
  # Note that if we can't find the process path by PID, we assume it's
  # allOpts[0] for the moment.

  const
    chalkPath = "/chalk.json"

  var
    n:        array[PATH_MAX, char]
    exe1path: string = ""
    info:     Stat
    chalk:    ChalkObj


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

  trace("Looking for a chalk file at: " & chalkPath)

  if stat(cstring(chalkPath), info) == 0:
    info("Found chalk mark in " & chalkPath)

    let
      cidOpt = getContainerName()
      cid    = cidOpt.getOrElse("<<in-container>")

    var  stream   = newFileStream(chalkPath)
    chalk         = newChalk(name         = exe1path,
                             fsRef        = exe1path,
                             stream       = newFileStream(exe1path),
                             containerId  = cidOpt.getOrElse(""),
                             pid          = some(pid),
                             resourceType = {ResourcePid, ResourceFile},
                             extract      = stream.extractOneChalkJson(cid),
                             codec        = getPluginByName("docker"))

    if chalk.containerId != "":
      chalk.resourceType = chalk.resourceType + {ResourceContainer}

    result = some(chalk)
    chalk.addToAllChalks()

  else:
    trace("Could not find a container chalk mark at " & chalkPath)
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
      chalk     = item
      chalk.pid = some(pid)
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

      chalk = newChalk(name         = exe1path,
                       fsRef        = exe1path,
                       stream       = newFileStream(exe1path),
                       resourceType = {ResourceFile},
                       codec        = getPluginByName("docker"))

      chalk.addToAllChalks()

    result = some(chalk)

    chalk.pid = some(pid)

proc getChildExitStatus(pid: Pid): bool =
  var stat_loc: cint

  let res = waitpid(pid, stat_loc, WNOHANG)

  if res == 0:
    return false

  assert WIFEXITED(stat_loc)
  setExitCode(WEXITSTATUS(stat_loc))
  return true

proc getParentExitStatus(trueParentPid: Pid): bool =
  if getppid() != trueParentPid:
    return true
  return false

proc doHeartbeatReport(chalkOpt: Option[ChalkObj]) =
  clearReportingState()
  initCollection()
  if chalkOpt.isSome():
    let chalk = chalkOpt.get()

    if not chalk.isMarked():
      addUnmarked(chalk.name)

    chalk.addToAllChalks()
    chalk.collectedData = ChalkDict()
    chalk.collectRunTimeArtifactInfo()
  doReporting()

template doHeartbeat(chalkOpt: Option[ChalkObj], pid: Pid, fn: untyped) =
  let
    inMicroSec    = int(chalkConfig.execConfig.getHeartbeatRate())
    sleepInterval = int(inMicroSec / 1000)

  setCommandName("heartbeat")

  while true:
    sleep(sleepInterval)
    chalkOpt.doHeartbeatReport()
    if fn(pid):
      break

template doHeartbeatAsChild(chalkOpt: Option[ChalkObj], pid: Pid) =
  chalkOpt.doHeartbeat(pid, getParentExitStatus)

template doHeartbeatAsParent(chalkOpt: Option[ChalkObj], pid: Pid) =
  chalkOpt.doHeartbeat(pid, getChildExitStatus)

proc runCmdExec*(args: seq[string]) =
  when not defined(posix):
    error("'exec' command not supported on this platform.")
    setExitCode(1)
    return


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
    setExitCode(1)
    return


  if len(allOpts) == 0:
    error("No executable named '" & cmdName & "' found in your path.")
    setExitCode(1)
    return

  var argsToPass = defaults

  if appendArgs:
    argsToPass &= args
  elif len(args) != 0 and not overrideOk:
    error("Cannot override default arguments on the command line.")
    setExitCode(1)
    return
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
      # add 1ms sleep so that the child process has a chance to exec before
      # we try to collect data from it otherwise the process data collected
      # might be about the chalk binary instead of the target binary, which
      #is incorrect
      #
      # Yes this is also racy but a proper fix will be more complicated
      sleep(1)
      initCollection()
      let chalkOpt = doExecCollection(allOpts, pid)
      if chalkOpt.isSome():
        chalkOpt.get().collectRunTimeArtifactInfo()
      doReporting()

      if execConfig.getHeartbeat():
        chalkOpt.doHeartbeatAsParent(pid)
      else:
        trace("Waiting for spawned process to exit.")
        var stat_loc: cint
        discard waitpid(pid, stat_loc, 0)
        setExitCode(WEXITSTATUS(stat_loc))
  else:
    if pid != 0:
      handleExec(allOpts, argsToPass)
    else:
      trace("Chalk is child process.")
      sleep(1)
      initCollection()
      trace("Host collection finished.")
      let chalkOpt = doExecCollection(allOpts, ppid)
      discard setpgid(0, 0) # Detach from the process group.
      # On some platforms we don't support
      if chalkOpt.isSome():
        chalkOpt.get().collectRunTimeArtifactInfo()
      doReporting()

      if execConfig.getHeartbeat():
        chalkOpt.doHeartbeatAsChild(ppid)
