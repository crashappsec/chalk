## This is for any common code for system stuff, such as executing
## code.
##
## :Author: John Viega :Copyright: 2023, Crash Override, Inc.

import  std/tempfiles, osproc, posix, posix_utils, config, subscan

proc getpass*(prompt: cstring) : cstring {.header: "<unistd.h>",
                                           header: "<pwd.h>",
                                          importc: "getpass".}

var
  tmpDirs:  seq[string] = @[]
  tmpFiles: seq[string] = @[]
  exitCode              = 0

template cleanTempFiles() =
  for dir in tmpDirs:
    try:
      trace("Removing tmp directory: " & dir)
      removeDir(dir)
    except:
      dumpExOnDebug()
      warn("Could not remove directory: " & dir)
  for file in tmpFiles:
    try:
      trace("Removing tmp file: " & file)
      removeFile(file)
    except:
      dumpExOnDebug()
      warn("Could not remove tmp file: " & file)

template moveError() =
  error("Could not move: " & item)

proc quitChalk*(errCode = exitCode) {.noreturn.} =
  if chalkConfig.getChalkDebug():
    if len(tmpDirs) != 0 or len(tmpFiles) != 0:
      error("Skipping cleanup; moving the following to ./chalk-tmp:")
      createDir("chalk-tmp")
      for item in tmpDirs & tmpFiles:
        let baseName = splitPath(item).tail
        error(item)
        if fileExists(item):
          try:
            moveFile(item, "chalk-tmp/" & baseName)
          except:
            moveError()
        else:
          try:
            moveDir(item, "chalk-tmp/" & baseName)
          except:
            moveError()
  else:
    cleanTempFiles()
  quit(errcode)

proc setExitCode*(code: int) =
  exitCode = code

proc getNewTempDir*(): string =
  result = createTempDir(tmpFilePrefix, tmpFileSuffix)
  tmpDirs.add(result)

proc getNewTempFile*(prefix = tmpFilePrefix, suffix = tmpFileSuffix,
                     autoDelete = true): (FileStream, string) =
  var (f, path) = createTempFile(prefix, suffix)
  if autoDelete:
    tmpFiles.add(path)

  result = (newFileStream(f), path)

proc registerTempFile*(path: string) =
  tmpFiles.add(path)

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

const
  S_IFMT  = 0xf000
  S_IFREG = 0x8000
  S_IXUSR = 0x0040
  S_IXGRP = 0x0008
  S_IXOTH = 0x0001
  S_IXALL = S_IXUSR or S_IXGRP or S_IXOTH

template isFile*(info: Stat): bool =
  (info.st_mode and S_IFMT) == S_IFREG

template hasUserExeBit*(info: Stat): bool =
  (info.st_mode and S_IXUSR) != 0

template hasGroupExeBit*(info: Stat): bool =
  (info.st_mode and S_IXGRP) != 0

template hasOtherExeBit*(info: Stat): bool =
  (info.st_mode and S_IXOTH) != 0

template hasAnyExeBit*(info: Stat): bool =
  (info.st_mode and S_IXALL) != 0

proc isExecutable*(path: string): bool =
  try:
    let info = stat(path)

    if not info.isFile():
      return false

    if not info.hasAnyExeBit():
      return false

    let myeuid = geteuid()

    if myeuid == 0:
      return true

    if info.st_uid == myeuid:
      return info.hasUserExeBit()

    var groupinfo: array[0 .. 255, Gid]
    let numGroups = getgroups(255, addr groupinfo)

    if info.st_gid in groupinfo[0 ..< numGroups]:
      return info.hasGroupExeBit()

    return info.hasOtherExeBit()

  except:
    return false # Couldn't stat.

proc findAllExePaths*(cmdName:    string,
                      extraPaths: seq[string] = @[],
                      usePath                 = true): seq[string] =
  ##
  ## The priority here is to the passed command name, but if and only
  ## if it is a path; we're assuming that they want to try to run
  ## something in a particular location.  Generally, we're disallowing
  ## this in config files, but it's here just in case.
  ##
  ## Our second priority is to the the extraPaths array, which is
  ## basically a programmer supplied PATH, in case the right place
  ## doesn't get picked up in our environment.
  ##
  ## If all else fails, we search the PATH environment variable.
  ##
  ## Note that we don't check for permissions problems (including
  ## not-executable), and we do not open the file, so there's the
  ## chance of the executable going away before we try to run it.
  ##
  ## The point is, the caller should eanticipate failure.
  let
    (mydir, me) = getMyAppPath().splitPath()
  var
    targetName  = cmdName
    allPaths    = extraPaths

  if usePath:
    allPaths &= getEnv("PATH").split(":")

  if '/' in cmdName:
    let tup    = resolvePath(cmdName).splitPath()
    targetName = tup.tail
    allPaths   = @[tup.head] & allPaths

  for item in allPaths:
    let path = resolvePath(item)
    if me == targetName and path == mydir: continue # Don't ever find ourself.
    let potential = joinPath(path, targetName)
    if potential.isExecutable():
      result.add(potential)

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

{.emit: """
#include <unistd.h>

int c_replace_stdin_with_pipe() {
  int filedes[2];

  pipe(filedes);
  dup2(filedes, 0);
  return filedes[1];
}

int c_write_to_pipe(int fd, char *s, int len) {
  ssize_t res;

  while(len > 0) {
   res = write(fd, s, len);
   if (res == -1) {
     return errno;
   }
   len -= res;
  }

  return 0;
}
""".}

proc cReplaceStdinWithPipe*(): cint {.importc: "c_replace_stdin_with_pipe".}
proc cWriteToPipe*(fd: cint, s: cstring, l: cint):
                 cint {.importc: "c_write_to_pipe".}

proc runWithNewStdin*(exe:      string,
                      args:     seq[string],
                      contents: string): int {.discardable.} =
  let
    fd   = cReplaceStdinWithPipe()
    subp = startProcess(exe,
                        args = args,
                        options = {poParentStreams})
    res  = cWriteToPipe(fd, cstring(contents), cint(len(contents) + 1))
  if res != 0:
    error("Write to pipe failed: " & $(strerror(res)))

  discard close(fd)
  let code = subp.waitForExit()
  subp.close()

  result = int(code)


template runCmdGetOutput*(exe: string, args: seq[string]): string =
  execProcess(exe, args = args, options = {})

type ExecOutput* = object
    stdout*:   string
    stderr*:   string
    exitCode*: int

proc readAllFromFd(fd: cint): string =
  var
    buf: array[0 .. 1024, char]

  while true:
    let n = read(fd, addr buf, 1024)
    if n <= 0: break
    var i: int = 0
    while i < n:
      let c = char(buf[i])
      result.add(c)
      i += 1
    if n == -1:
      error($(strerror(errno)))
      quit(1)

template ccall(code: untyped, success = 0) =
  let ret = code

  if ret != success:
    error($(strerror(ret)))
    quit(1)

proc runCmdGetEverything*(exe:      string,
                          args:     seq[string],
                          newStdIn: string       = ""): ExecOutput =
  var
    stdOutPipe: array[0 .. 1, cint]
    stdErrPipe: array[0 .. 1, cint]
    stdInPipe:  array[0 .. 1, cint]

  trace("Running: " & exe & " " & args.join(" "))
  ccall pipe(stdOutPipe)
  ccall pipe(stdErrPipe)

  if newStdIn != "":
    ccall pipe(stdInPipe)

  let pid = fork()
  if pid != 0:
    ccall close(stdOutPipe[1])
    ccall close(stdErrPipe[1])
    if newStdIn != "":
      ccall close(stdInPipe[0])
      let res = cWriteToPipe(stdInPipe[1], cstring(newStdIn),
                             cint(len(newStdIn)))
      if res != 0:
        error("Write to pipe failed: " & $(strerror(res)))
      ccall close(stdInPipe[1])
    var stat_ptr: cint
    trace("Waiting for pid = " & $(pid))
    discard waitpid(pid, stat_ptr, 0)
    result.exitCode = int(WEXITSTATUS(stat_ptr))
    result.stdout   = readAllFromFd(stdOutPipe[0])
    result.stderr   = readAllFromFd(stdErrPipe[0])
    ccall close(stdOutPipe[0])
    ccall close(stdErrPipe[0])
  else:
    let cargs = allocCStringArray(@[exe] & args)
    if newStdIn != "":
      ccall close(stdInPipe[1])
      discard dup2(stdInPipe[0], 0)
      ccall close(stdInPipe[0])
    ccall close(stdOutPipe[0])
    ccall close(stdErrPipe[0])
    discard dup2(stdOutPipe[1], 1)
    discard dup2(stdErrPipe[1], 2)
    ccall close(stdOutPipe[1])
    ccall close(stdErrPipe[1])
    ccall(execv(cstring(exe), cargs), -1)
    error(exe & ": command not found")
    quit(-1)

  if chalkConfig.getChalkDebug():
    trace("command returned error code: " & $result.exitCode)
    trace("stderr = " & result.stderr)
    trace("stdout = " & result.stdout)


template getStdout*(o: ExecOutput): string = o.stdout
template getStderr*(o: ExecOutput): string = o.stderr
template getExit*(o: ExecOutput): int      = o.exitCode


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

template withWorkingDir*(dir: string, code: untyped) =
  let
    toRestore = getCurrentDir()

  try:
    setCurrentDir(dir)
    trace("Set current working directory to: " & dir)
    code
  finally:
    setCurrentDir(toRestore)
    trace("Restored current working directory to: " & toRestore)

proc tryToLoadFile*(fname: string): string =
  try:
    return readFile(fname)
  except:
    return ""

proc tryToWriteFile*(fname: string, contents: string): bool =
  try:
    writeFile(fname, contents)
    return true
  except:
    return false

proc tryToCopyFile*(fname: string, dst: string): bool =
  try:
    copyFile(fname, dst)
    return true
  except:
    return false

proc getPasswordViaTty*(): string {.discardable.} =
  if isatty(0) == 0:
    error("Cannot read password securely when not run from a tty.")
    return ""

  var pw = getpass(cstring("Enter password for decrypting the private key: "))

  result = $(pw)

  for i in 0 ..< len(pw):
    pw[i] = char(0)

proc delByValue*[T](s: var seq[T], x: T): bool {.discardable.} =
  let ix = s.find(x)
  if ix == -1:
    return false

  s.delete(ix)
  return true

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


proc getBoxType*(b: Box): Con4mType =
  case b.kind
  of MkStr:   return stringType
  of MkInt:   return intType
  of MkFloat: return floatType
  of MkBool:  return boolType
  of MkSeq:
    var itemTypes: seq[Con4mType]
    let l = unpack[seq[Box]](b)

    if l.len() == 0:
      return newListType(newTypeVar())

    for item in l:
      itemTypes.add(item.getBoxType())
    for item in itemTypes[1..^1]:
      if item.unify(itemTypes[0]).isBottom():
        return Con4mType(kind: TypeTuple, itemTypes: itemTypes)
    return newListType(itemTypes[0])
  of MkTable:
    # This is a lie, but con4m doesn't have real objects, or a "Json" / Mixed
    # type, so we'll just continue to special case dicts.
    return newDictType(stringType, newTypeVar())
  else:
    return newTypeVar() # The JSON "Null" can stand in for any type.

proc checkAutoType*(b: Box, t: Con4mType): bool =
  return not b.getBoxType().unify(t).isBottom()
