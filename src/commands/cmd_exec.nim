##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk exec` command.

import std/[
  options,
  posix,
  sequtils,
]
import ".."/[
  chalkjson,
  collect,
  config,
  plugin_api,
  reporting,
  run_management,
  subscan,
  types,
  utils/exec,
  utils/files,
  utils/sets,
  utils/times,
]

when hostOS == "macosx":
  proc proc_pidpath(pid: Pid, pathbuf: pointer, len: uint32): cint
    {.cdecl, header: "<libproc.h>", importc.}

when hostOS == "linux":
  import std/inotify

else:
  type InotifyEvent = object
    wd*: FileHandle
    mask*: uint32
    cookie*: uint32
    len*: uint32
    name*: char

  iterator inotify_events(evs: pointer, n: int): ptr InotifyEvent =
    discard

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
    extract:  ChalkDict

  when hostOS == "macosx":
    if proc_pidpath(pid, addr n[0], PATH_MAX) > 0:
      exe1path =  $(cast[cstring](addr n[0]))
  elif hostOS == "linux":
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
      cidOpt      = getContainerName()
      cid         = cidOpt.getOrElse("<<in-container>")

    withFileStream(chalkPath, mode = fmRead, strict = false):
      if stream == nil:
        error(chalkPath & ": Could not read chalkmark")
        return none(ChalkObj)
      extract = stream.extractOneChalkJson(cid)

    chalk         = newChalk(name         = exe1path,
                             fsRef        = exe1path,
                             containerId  = cidOpt.getOrElse(""),
                             pid          = some(pid),
                             resourceType = {ResourcePid, ResourceFile},
                             extract      = extract,
                             codec        = getPluginByName("docker"))

    for k, v in chalk.extract:
      chalk.collectedData[k] = v

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
  initCollection()
  if chalkOpt.isSome():
    let chalk = chalkOpt.get()

    chalk.addToAllChalks()
    chalk.collectedData = ChalkDict()

    if not chalk.isMarked():
      addUnmarked(chalk.name)
    else:
      for k, v in chalk.extract:
        chalk.collectedData[k] = v

    chalk.collectRunTimeArtifactInfo()
  doReporting(clearState = true)

proc doHeartbeat(chalkOpt: Option[ChalkObj], pid: Pid, fn: (pid: Pid) -> bool) =
  let
    inMicroSec    = int(attrGet[Con4mDuration]("exec.heartbeat.rate"))
    sleepInterval = int(inMicroSec / 1000)
    limit         = int(attrGet[Con4mSize]("exec.heartbeat.rlimit"))
    niceValue     = attrGet[int]("exec.heartbeat.nice")

  trace("heartbeat: using nice " & $niceValue)
  discard nice(cint(niceValue))

  setCommandName("heartbeat")
  setRlimit(limit)

  while true:
    sleep(sleepInterval)
    chalkOpt.doHeartbeatReport()
    if fn(pid):
      break

type PostExecState = ref object
  toWatchPaths: seq[string]
  watcher:      FileHandle
  watchedDirs:  TableRef[FileHandle, string]

when hostOS == "linux":
  proc initPostExecWatch(): Option[PostExecState] =
    if not attrGet[bool]("exec.postexec.run"):
      return none(PostExecState)

    let tmp = attrGet[string]("exec.postexec.access_watch.prep_tmp_path")
    if not fileExists(tmp):
      return none(PostExecState)

    let
      toWatchPaths = tryToLoadFile(tmp).splitLinesAnd(keepEmpty = false)
      watcher      = inotify_init1(O_NONBLOCK)
    var
      toWatchDirs  = initHashSet[string]()
      watchedDirs  = newTable[FileHandle, string]()

    if watcher < 0:
      error("inotify: " & $osLastError())
      return none(PostExecState)

    # watch dirs where artifacts are contained to:
    # * reduces inotify FD overhead
    # * contains name in the watched event struct
    for c in toWatchPaths:
      if c == "":
        continue
      let (dir, _) = c.splitPath()
      toWatchDirs.incl(dir)

    for d in toWatchDirs:
      let wd = inotify_add_watch(watcher, cstring(d), IN_ACCESS)
      if wd < 0:
        error("inotify: could not watch " & d)
        continue
      trace("inotify: watching " & d)
      watchedDirs[wd] = d

    return some(PostExecState(
      toWatchPaths: toWatchPaths,
      watcher:      watcher,
      watchedDirs:  watchedDirs,
    ))

else:
  proc initPostExecWatch(): Option[PostExecState] =
    return none(PostExecState)

proc doPostExec(state: Option[PostExecState], detach: bool) =
  if state.isNone():
    return

  let toFork = attrGet[bool]("exec.postexec.fork")
  if toFork:
    let pid = fork()
    if pid != 0:
      # parent process
      return

  let
    ws            = state.get()
    niceValue     = attrGet[int]("exec.postexec.nice")
  var
    accessedPaths = initHashSet[string]()

  trace("postexec: using nice " & $niceValue)
  discard nice(cint(niceValue))

  try:
    initCollection()
    setCommandName("postexec")
    if detach:
      detachFromParent()

    let
      pollInMicroSec     = int(attrGet[Con4mDuration]("exec.postexec.access_watch.initial_poll_time"))
      intervalInMicroSec = int(attrGet[Con4mDuration]("exec.postexec.access_watch.initial_poll_interval"))
      pollMs             = int(pollInMicroSec / 1000)
      intervalMs         = int(intervalInMicroSec / 1000)
      start              = getMonoTime()

    trace("postexec: polling " & $pollMs & "ms every " & $intervalMs & "ms")
    while (getMonoTime() - start).inMilliseconds <= pollMs:
      sleep(intervalMs)
      var buffer = newSeq[byte](8192)
      while (
        let n = read(ws.watcher, buffer[0].addr, 8192)
        n
      ) > 0:
        for e in inotify_events(buffer[0].addr, n):
          let
            name = $cast[cstring](addr e[].name)
            wd   = e[].wd
          if wd notin ws.watchedDirs:
            error("postexec: inotify notified for non-watched wd")
          let
            dir  = ws.watchedDirs[wd]
            path = joinPath(dir, name)
          if path in ws.toWatchPaths:
            trace("postexec: found accessed artifact " & path)
            accessedPaths.incl(path)
          else:
            trace("postexec: ignoring accessed non-artifact " & path)

  finally:
    discard close(ws.watcher)

  let codecs = attrGet[seq[string]]("exec.postexec.access_watch.scan_codecs")

  trace("postexec: subscan for chalkmarks in " &
        $len(accessedPaths) & " accessed artifacts " &
        "out of known " & $len(ws.toWatchPaths) & " artifacts")
  withOnlyCodecs(getPluginsByName(codecs)):
    for chalk in runChalkSubScan(ws.toWatchPaths, "extract").allChalks:
      chalk.accessed = some(chalk.fsRef in accessedPaths)
      if chalk.accessed.get():
        trace(chalk.fsRef & ": chalkmark accessed")
      else:
        trace(chalk.fsRef & ": chalkmark not accessed")
      # as its a subscan, artifact info is not collected hence needs to be manually triggered
      chalk.collectRunTimeArtifactInfo()
      addToAllArtifacts(chalk)
  trace("postexec: subscan complete")

  withSuspendChalkCollectionFor(getOptionalPluginNames()):
    doReporting(clearState = true)

  # if forked exit postexec process
  if toFork:
    quitChalk()
  # else restore previous nice as chalk can be doing things after postexec
  else:
    trace("postexec: reverting nice " & $niceValue)
    discard nice(cint(niceValue * -1))

proc runCmdExec*(args: seq[string]) =
  when not defined(posix):
    error("'exec' command not supported on this platform.")
    setExitCode(1)
    return

  let
    fromArgs   = attrGet[bool]("exec.command_name_from_args")
    cmdPath    = attrGet[seq[string]]("exec.search_path")
    defaults   = attrGet[seq[string]]("exec.default_args")
    appendArgs = attrGet[bool]("exec.append_command_line_args")
    overrideOk = attrGet[bool]("exec.override_ok")
    usePath    = attrGet[bool]("exec.use_path")
    pct        = attrGet[int]("exec.reporting_probability")
    ppid       = getpid()   # Get the current pid before we fork.
  var
    cmdName    = attrGet[string]("exec.command_name")

  var argsToPass = defaults

  if appendArgs:
    argsToPass &= args
  elif len(args) != 0 and not overrideOk:
    error("Cannot override default arguments on the command line.")
    setExitCode(1)
    return
  elif len(args) != 0:
    argsToPass = args

  if cmdName == "" and fromArgs and len(argsToPass) > 0:
    cmdName = argsToPass[0]
    argsToPass.delete(0..0)

  if cmdName == "":
    error("This chalk instance has no configured process to exec.")
    error("At the command line, you can pass --exec-command-name to " &
          "set the program name (PATH is searched).")
    error("Add extra directories to search with --exec-search-path.")
    error("In a config file, set exec.command_name and/or exec.search_path")
    setExitCode(1)
    return

  let allOpts = findAllExePaths(cmdName, cmdPath, usePath)
  if len(allOpts) == 0:
    error("No executable named '" & cmdName & "' found in your path.")
    setExitCode(1)
    return

  if pct != 100:
    let
      inRange = pct/100
      randVal = randInt() / high(int)

    if randVal > inRange:
      handleExec(allOpts, argsToPass)

  let
    postExecState = initPostExecWatch()
    pid           = fork()

  if attrGet[bool]("exec.chalk_as_parent"):
    if pid == 0:
      handleExec(allOpts, argsToPass)
    elif pid == -1:
      error("Chalk could not fork child process to exec " & cmdName)
      setExitCode(1)
    else:
      trace("Chalk is parent process: " & $(ppid) & ". Child pid: " & $(pid))
      # add some sleep so that the child process has a chance to exec before
      # we try to collect data from it otherwise the process data collected
      # might be about the chalk binary instead of the target binary, which
      # is incorrect
      #
      # Yes this is also racy but a proper fix will be more complicated.
      let
        inMicroSec   = int(attrGet[Con4mDuration]("exec.initial_sleep_time"))
        initialSleep = int(inMicroSec / 1000)

      sleep(initialSleep)

      initCollection()
      trace("Host collection finished.")
      let chalkOpt = doExecCollection(allOpts, pid)
      if chalkOpt.isSome():
        chalkOpt.get().collectRunTimeArtifactInfo()
      doReporting(clearState = true)

      postExecState.doPostExec(detach = false)

      if attrGet[bool]("exec.heartbeat.run"):
        chalkOpt.doHeartbeat(pid, getChildExitStatus)
      else:
        trace("Waiting for spawned process to exit.")
        var stat_loc: cint
        discard waitpid(pid, stat_loc, 0)
        setExitCode(WEXITSTATUS(stat_loc))
  else:
    if pid == -1:
      error("Chalk could not fork process for metadata collection. " &
            "No chalk reports will be sent.")
    elif pid != 0:
      trace("Chalk is forking itself for metadata collection. " &
            "Exec pid: " & $(ppid) & " " &
            "Child pid: " & $(pid))
      handleExec(allOpts, argsToPass)
    else:
      let cpid = getpid() # get pid after fork of child process
      trace("Chalk is child process: " & $(cpid))

      let
        inMicroSec   = int(attrGet[Con4mDuration]("exec.initial_sleep_time"))
        initialSleep = int(inMicroSec / 1000)

      sleep(initialSleep)

      initCollection()
      trace("Host collection finished.")
      let chalkOpt = doExecCollection(allOpts, ppid)
      detachFromParent()
      # On some platforms we don't support
      if chalkOpt.isSome():
        chalkOpt.get().collectRunTimeArtifactInfo()
      doReporting(clearState = true)

      postExecState.doPostExec(detach = true)

      if attrGet[bool]("exec.heartbeat.run"):
        chalkOpt.doHeartbeat(ppid, getParentExitStatus)
