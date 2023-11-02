##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This is for any common code for system stuff, such as executing
## code.

import  std/tempfiles, osproc, posix, config, subscan, nimutils/managedtmp,
        std/monotimes, parseutils

proc increfStream*(chalk: ChalkObj) {.exportc.} =
  if chalk.streamRefCt != 0:
    chalk.streamRefCt += 1
    return

  chalk.streamRefCt = 1

  if len(cachedChalkStreams) >= chalkConfig.getCacheFdLimit():
    let removing = cachedChalkStreams[0]

    trace("Too many cached file descriptors. Closing fd for: " & chalk.name)
    try:
      removing.stream.close()
    except:
      discard

    removing.stream      = FileStream(nil)
    removing.streamRefCt = 0
    cachedChalkStreams = cachedChalkStreams[1 .. ^1]

  cachedChalkStreams.add(chalk)

proc decrefStream*(chalk: ChalkObj) =
  chalk.streamRefCt -= 1

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
  let customTmpDirOpt = chalkConfig.getDefaultTmpDir()

  if customTmpDirOpt.isSome() and not existsEnv("TMPDIR"):
    putenv("TMPDIR", customTmpDirOpt.get())

  if chalkConfig.getChalkDebug():
    info("Debug is on; temp files / dirs will be moved, not deleted.")
    setManagedTmpCopyLocation(resolvePath("chalk-tmp"))

  setManagedTmpExitCallback(reportTmpFileExitState)
  setDefaultTmpFilePrefix(tmpFilePrefix)
  setDefaultTmpFileSuffix(tmpFileSuffix)


when hostOs == "macosx":
  const staticScriptLoc = "autocomplete/mac.bash"
else:
  const staticScriptLoc = "autocomplete/default.bash"

const
  bashScript      = staticRead(staticScriptLoc)
  autoCompleteLoc = "~/.local/share/bash_completion/completions/chalk.bash"

when hostOs == "linux":
  template makeCompletionAutoSource() =
    var
      acpath  = resolvePath("~/.bash_completion")
      f       = newFileStream(acpath, fmReadWriteExisting)
      toWrite = ". " & dst & "\n"

    if f == nil:
      f = newFileStream(acpath, fmWrite)
      if f == nil:
        warn("Cannot write to " & acpath & " to turn on autocomplete.")
        return
    else:
      try:
        let
          contents = f.readAll()
        if toWrite in contents:
          f.close()
          return
        if len(contents) != 0 and contents[^1] != '\n':
          f.write("\n")
      except:
        warn("Cannot write to ~/.bash_completion to turn on autocomplete.")
        dumpExOnDebug()
        f.close()
        return
    f.write(toWrite)
    f.close()
    info("Added sourcing of autocomplete to ~/.bash_completion file")
elif hostOs == "macosx":
  template makeCompletionAutoSource() =
    var
      acpath = resolvePath("~/.zshrc")
      f      = newFileStream(acpath, fmReadWriteExisting)

    if f == nil:
      f = newFileStream(acPath, fmWrite)
      if f == nil:
        warn("Cannot write to " & acpath & " to turn on autocomplete.")
        return

    var
      contents: string
      foundbci = false
      foundci  = false
      foundsrc = false
    try:
      contents = f.readAll()
    except:
      discard
    let
      lines   = contents.split("\n")
      srcLine = "source " & dst

    for line in lines:
      # This is not even a little precise but should be ok
      let words = line.split(" ")
      if "bashcompinit" in words:
        foundbci = true
      elif "compinit" in words:
        foundci = true
      elif line == srcLine and foundci and foundbci:
        foundsrc = true

    if foundbci and foundci and foundsrc:
      return

    if len(contents) != 0 and contents[^1] != '\n':
      f.write("\n")

    if not foundbci:
      f.writeLine("autoload bashcompinit")
      f.writeLine("bashcompinit")

    if not foundci:
      f.writeLine("autoload -Uz compinit")
      f.writeLine("compinit")

    if not foundsrc:
      f.writeLine(srcLine)

    f.close()
    info("Set up sourcing of basic autocomplete in ~/.zshrc")

else:
    template makeCompletionAutoSource() = discard

const currentAutocompleteVersion = (0, 1, 3)

proc validateMetadata*(obj: ChalkObj): ValidateResult {.importc.}

proc autocompleteFileCheck*() =
  if isatty(0) == 0 or chalkConfig.getInstallCompletionScript() == false:
    return
  let
    dst           = resolvePath(autoCompleteLoc)
    alreadyExists = fileExists(dst)

  if alreadyExists:
    var invalidMark = true

    let
      subscan   = runChalkSubscan(dst, "extract")
      allchalks = subscan.getallChalks()

    if len(allChalks) != 0 and allChalks[0].extract != nil:
      if "ARTIFACT_VERSION" in allChalks[0].extract and
         allChalks[0].validateMetadata() == vOk:
        let
          boxedVers    = allChalks[0].extract["ARTIFACT_VERSION"]
          foundRawVers = unpack[string](boxedVers)
          splitVers    = foundRawVers.split(".")

        if len(splitVers) == 3:
          var
            major, minor, patch: int
            totalParsed = 2

          totalParsed += parseInt(splitVers[0], major)
          totalParsed += parseInt(splitVers[1], minor)
          totalParsed += parseInt(splitVers[2], patch)

          if totalParsed == len(foundRawVers):
            invalidMark = false

            trace("Extracted semver string from existing autocomplete file: " &
                  foundRawVers)

          if (major, minor, patch) != (0, 0, 0) and
             currentAutoCompleteVersion > (major, minor, patch):
            var curVers = $(currentAutocompleteVersion[0]) & "." &
                          $(currentAutocompleteVersion[1]) & "." &
                          $(currentAutocompleteVersion[2])

            info("Updating autocomplete script to version: " & curVers)
          else:
            trace("Autocomplete script does not need updating.")
            return

    if invalidMark:
      info("Invalid chalk mark in autocompletion script. Updating.")

  if not alreadyExists:
    try:
      createDir(resolvePath(dst.splitPath().head))
    except:
      warn("No permission to create auto-completion directory: " &
        dst.splitPath().head)
      return

  if not tryToWriteFile(dst, bashScript):
    warn("Could not write to auto-completion file: " & dst)
    return
  else:
    info("Installed bash auto-completion file to: " & dst)

  if not alreadyExists:
    makeCompletionAutoSource()
    info("Script should be sourced automatically on your next login.")

template otherSetupTasks*() =
  setupManagedTemp()
  autocompleteFileCheck()
  if isatty(1) == 0:
    setShowColor(false)

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

proc runProcNoOutputCapture*(exe:      string,
                             args:     seq[string],
                             newStdin = ""): int {.discardable.} =

  let execOutput = runCmdGetEverything(exe, args, newStdIn,
                                       passthrough = true,
                                       timeoutUsec = 0) # No timeout
  result = execOutput.getExit()


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
