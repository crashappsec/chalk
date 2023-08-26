## This is for any common code for system stuff, such as executing
## code.
##
## :Author: John Viega :Copyright: 2023, Crash Override, Inc.

import  std/tempfiles, osproc, posix, config, subscan, nimutils/managedtmp,
        std/monotimes

let sigNameMap = { 1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL",
                   6: "SIGABRT",7: "SIGBUS", 9: "SIGKILL", 11: "SIGSEGV",
                   15: "SIGTERM" }.toTable()

proc regularTerminationSignal(signal: cint) {.noconv.} =
  try:
    error("Aborting due to signal: " & sigNameMap[signal] & "(" & $(signal) &
      ")")
    if chalkConfig.getChalkDebug():
      publish("debug", "Stack trace: \n" & getStackTrace())

  except:
    echo "Aborting due to signal: " & sigNameMap[signal]  & "(" & $(signal) &
      ")"
    dumpExOnDebug()
  var sigset:  SigSet

  discard sigemptyset(sigset)

  for signal in [SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGABRT, SIGBUS, SIGKILL,
                 SIGSEGV, SIGTERM]:
    discard sigaddset(sigset, signal)
  discard sigprocmask(SIG_SETMASK, sigset, sigset)


  tmpfile_on_exit()
  exitnow(signal + 128)

proc setupSignalHandlers*() =
  var handler: SigAction

  handler.sa_handler = regularTerminationSignal
  handler.sa_flags   = 0

  for signal in [SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGABRT, SIGBUS, SIGKILL,
                 SIGSEGV, SIGTERM]:
    discard sigaction(signal, handler, nil)


proc reportTmpFileExitState*(files, dirs, errs: seq[string]) =
  for err in errs:
    error(err)

  if chalkConfig.getChalkDebug() and len(dirs) + len(files) != 0:
    error("Due to --debug flag, skipping cleanup; moving the " &
          "following to ./chalk-tmp:")
    for item in files & dirs:
      error(item)

  if chalkConfig.getReportTotalTime():
    echo "Total run time: " & $(int(getMonoTime().ticks() - startTime) /
                                1000000000) &
      " seconds"


proc setupManagedTemp*() =
  if chalkConfig.getChalkDebug():
    info("Debug is on; temp files / dirs will be moved, not deleted.")
    setManagedTmpCopyLocation(resolvePath("chalk-tmp"))
  setManagedTmpExitCallback(reportTmpFileExitState)
  setDefaultTmpFilePrefix(tmpFilePrefix)
  setDefaultTmpFileSuffix(tmpFileSuffix)

var exitCode = 0

proc quitChalk*(errCode = exitCode) {.noreturn.} =
  quit(errcode)

proc setExitCode*(code: int) =
  exitCode = code

proc replaceFileContents*(chalk: ChalkObj, contents: string): bool =
  if chalk.fsRef == "":
    error(chalk.name & ": replaceFileContents() called on an artifact that " &
          "isn't associated with a file.")
    return false

  result = true

  var
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
    ctx       = newFileStream(f)
    info: Stat

  try:
    ctx.write(contents)
  finally:
    if ctx != nil:
      try:
        ctx.close()
        # If we can successfully stat the file, we will try to
        # re-apply the same mode bits via chmod after the move.
        let statResult = stat(cstring(chalk.fsRef), info)
        moveFile(chalk.fsRef, path & ".old")
        moveFile(path, chalk.fsRef)
        if statResult == 0:
          discard chmod(cstring(chalk.fsRef), info.st_mode)
      except:
        removeFile(path)
        if not fileExists(chalk.fsRef):
          # We might have managed to move it but not copy the new guy in.
          try:
            moveFile(path & ".old", chalk.fsRef)
          except:
            error(chalk.fsRef & " was moved before copying in the new " &
              "file, but the op failed, and the file could not be replaced. " &
              " It currently is in: " & path & ".old")
        else:
            error(chalk.fsRef & ": Could not write (no permission)")
        dumpExOnDebug()
        return false

proc findExePath*(cmdName:    string,
                  extraPaths: seq[string] = @[],
                  usePath         = true,
                  ignoreChalkExes = false): Option[string] =
  var foundExes = findAllExePaths(cmdName, extraPaths, usePath)

  if ignoreChalkExes:
    var newExes: seq[string]

    startNativeCodecsOnly()

    for location in foundExes:
      let
        subscan   = runChalkSubScan(location, "extract")
        allchalks = subscan.getAllChalks()
      if len(allChalks) != 0 and allChalks[0].extract != nil and
         "$CHALK_IMPLEMENTATION_NAME" in allChalks[0].extract:
        continue
      else:
        newExes.add(location)

    endNativeCodecsOnly()

    foundExes = newExes

  if foundExes.len() == 0:
    trace("Could not find '" & cmdName & "' in path.")
    return none(string)

  trace("Found '" & cmdName & "' in path: " & foundExes[0])
  return some(foundExes[0])

proc handleExec*(prioritizedExes: seq[string], args: seq[string]) {.noreturn.} =
  if len(prioritizedExes) != 0:
    let cargs = allocCStringArray(@[prioritizedExes[0].splitPath.tail] & args)


    for path in prioritizedExes:
      trace("execve: " & path & " " & args.join(" "))
      discard execv(cstring(path), cargs)
      # Either execv doesn't return, or something went wrong. No need to check the
      # error code.
      error("Chalk: when execing '" & path & "': " & $(strerror(errno)))

  error("Chalk: exec could not find a working executable to run.")
  quitChalk(1)

proc runWithNewStdin*(exe:      string,
                      args:     seq[string],
                      contents: string): int {.discardable.} =
  let
    fd   = cReplaceStdinWithPipe()
    subp = startProcess(exe,
                        args = args,
                        options = {poParentStreams})
  if not fWriteData(fd, contents):
    error("Write to pipe failed: " & $(strerror(errno)))

  discard close(fd)
  let code = subp.waitForExit()
  subp.close()

  result = int(code)

# I'd rather these live in docker_base.nim, but it'd be more work than
# it's worth to make that happen.
proc runWrappedDocker*(args: seq[string], df: string): int {.discardable.} =
  trace("Running docker w/ stdin dockerfile by calling: " & dockerExeLocation &
    " " & args.join(" "))

  let code = runWithNewStdin(dockerExeLocation, args, df)

  if code != 0:
    trace("Docker exited with code: " & $(code))

proc runDocker*(args: seq[string]): int {.discardable.} =
  trace("Running: " & dockerExeLocation & " " & args.join(" "))

  let pid = fork()
  if pid != 0:
    var stat_ptr: cint
    discard waitpid(pid, stat_ptr, 0)
    result = int(WEXITSTATUS(stat_ptr))
    if result != 0:
      trace("Docker exited with code: " & $(result))
  else:
    let cArgs = allocCStringArray(@[dockerExeLocation] & args)
    discard execv(cstring(dockerExeLocation), cargs)

template runWrappedDocker*(info: DockerInvocation): int =
  let res = runDocker(info.newCmdLine)
  if res != 0:
    error("Wrapped docker call failed; reverting to original docker cmd")
    raise newException(ValueError, "doh")
  res

proc doReporting*(topic: string){.importc.}

proc dockerFailsafe*(info: DockerInvocation) {.noreturn.} =
  var exitCode: int
  if info.dockerFileLoc == ":stdin:":
    exitCode = runWrappedDocker(info.originalArgs, info.inDockerFile)
  else:
    exitCode = runDocker(info.originalArgs)
  doReporting("fail")
  quitChalk(exitCode)

proc increfStream*(chalk: ChalkObj) =
  if chalk.streamRefCt != 0:
    chalk.streamRefCt += 1
    return

  chalk.streamRefCt = 1

  if len(cachedChalkStreams) + 1 == chalkConfig.getCacheFdLimit():
    let removing = cachedChalkStreams[0]

    trace("Too many cached file descriptors. Closing fd for: " & chalk.name)
    try:
      removing.stream.close()
    except:
      discard

    removing.stream      = FileStream(nil)
    removing.streamRefCt = 0

  cachedChalkStreams.add(chalk)

proc decrefStream*(chalk: ChalkObj) =
  chalk.streamRefCt -= 1

template chalkUseStream*(chalk: ChalkObj, code: untyped) {.dirty.} =
  var
    stream:  FileStream
    noRead:  bool
    noWrite: bool

  if chalk.fsRef == "":
    noRead  = true
    noWrite = true
  else:
    if chalk.stream == nil:
      chalk.stream = newFileStream(chalk.fsRef, fmReadWriteExisting)

      if chalk.stream == nil:
        trace(chalk.fsRef & ": Cannot open for writing.")
        noWrite = true
        chalk.stream = newFileStream(chalk.fsRef, fmRead)

        if chalk.stream == nil:
          error(chalk.fsRef & ": Cannot open for reading either.")
          noRead = true
        else:
          chalk.increfStream()
          trace(chalk.fsRef & ": File stream opened for reading.")
      else:
        chalk.increfStream()
        trace(chalk.fsRef & ": File stream opened for writing.")
    else:
      chalk.increfStream()
      trace(chalk.fsRef & ": File stream is cached.")

    if chalk.stream != nil:
      try:
        stream = chalk.stream
        stream.setPosition(0)
        code
      finally:
        chalk.decrefStream()

template chalkCloseStream*(chalk: ChalkObj) =
  if chalk.stream != nil:
    chalk.stream.close()

  chalk.stream      = nil
  chalk.streamRefCt = 0

  delByValue(cachedChalkStreams, chalk)
