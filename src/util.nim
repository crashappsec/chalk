##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This is for any common code for system stuff, such as executing
## code.

import std/[httpcore, tempfiles, posix, exitprocs, sets, times, monotimes]
from std/unicode import validateUtf8
import pkg/[nimutils/managedtmp]
import "."/[config, subscan, fd_cache, semver]
export fd_cache

let sigNameMap = { 1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL",
                   6: "SIGABRT",7: "SIGBUS", 9: "SIGKILL", 11: "SIGSEGV",
                   15: "SIGTERM" }.toTable()

var
  LC_ALL {.importc, header: "<locale.h>".}: cint
  savedTermState: Termcap

proc restoreTerminal() {.noconv.} =
  tcSetAttr(cint(1), TcsaConst.TCSAFLUSH, savedTermState)

proc regularTerminationSignal(signal: cint) {.noconv.} =
  let pid = getpid()
  try:
    error("pid: " & $(pid) & " - Aborting due to signal: " &
          sigNameMap[signal] & "(" & $(signal) & ")")
    if attrGet[bool]("chalk_debug"):
      publish("debug", "Stack trace: \n" & getStackTrace())

  except:
    echo("pid: " & $(pid) & " - Aborting due to signal: " &
         sigNameMap[signal]  & "(" & $(signal) & ")")
    dumpExOnDebug()
  var sigset:  SigSet

  discard sigemptyset(sigset)

  for signal in [SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGABRT, SIGBUS, SIGKILL,
                 SIGSEGV, SIGTERM]:
    discard sigaddset(sigset, signal)
  discard sigprocmask(SIG_SETMASK, sigset, sigset)


  tmpfile_on_exit()

  exitnow(signal + 128)

proc setlocale(category: cint, locale: cstring): cstring {. importc, cdecl,
                                nodecl, header: "<locale.h>", discardable .}

proc setupTerminal*() =
  setlocale(LC_ALL, cstring(""))
  tcGetAttr(cint(1), savedTermState)
  addExitProc(restoreTerminal)

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

  if attrGet[bool]("chalk_debug") and len(dirs) + len(files) != 0:
    error("Due to --debug flag, skipping cleanup; moving the " &
          "following to ./chalk-tmp:")
    for item in files & dirs:
      error(item)

  let monoEndTime = getMonoTime()
  if attrGet[bool]("report_total_time"):
    echo("Total run time: " & $(monoEndTime - monoStartTime))

proc canOpenFile*(path: string, mode: FileMode = FileMode.fmRead): bool =
  var canOpen = false
  try:
    let stream = openFileStream(path, mode = mode)
    if stream != nil:
      canOpen = true
      stream.close()
  except:
    dumpExOnDebug()
    error(getCurrentExceptionMsg())
  finally:
    if mode != FileMode.fmRead:
      try:
        discard tryRemoveFile(path)
      except:
        discard
  return canOpen

proc setupManagedTemp*() =
  let customTmpDirOpt = attrGetOpt[string]("default_tmp_dir")

  if customTmpDirOpt.isSome() and not existsEnv("TMPDIR"):
    putenv("TMPDIR", customTmpDirOpt.get())

  # temp folder needs to exist in order to successfully create
  # tmp files otherwise nim's createTempFile throws segfault
  # when TMPDIR does not exist
  if existsEnv("TMPDIR"):
    discard existsOrCreateDir(getEnv("TMPDIR"))

  if attrGet[bool]("chalk_debug"):
    let
      tmpPath = resolvePath("chalk-tmp")
      tmpCheck = resolvePath(".chalk-tmp-check")
    if canOpenFile(tmpCheck, mode = FileMode.fmWrite):
      info("Debug is on; temp files / dirs will be moved to " & tmpPath & ", not deleted.")
      setManagedTmpCopyLocation(tmpPath)
    else:
      warn("Debug is on however chalk is unable to move temp files to " & tmpPath)

  setManagedTmpExitCallback(reportTmpFileExitState)
  setDefaultTmpFilePrefix(tmpFilePrefix)
  setDefaultTmpFileSuffix(tmpFileSuffix)

proc otherSetupTasks*() =
  setupManagedTemp()
  if isatty(1) == 0:
    setShowColor(false)
  limitFDCacheSize(attrGet[int]("cache_fd_limit"))

var exitCode = 0

proc quitChalk*(errCode = exitCode) {.noreturn.} =
  quit(errCode)

proc getExitCode*(): int =
  return exitCode

proc setExitCode*(code: int): int {.discardable.} =
  exitCode = code
  return code

proc replaceFileContents*(chalk: ChalkObj, contents: string): bool =
  if chalk.fsRef == "":
    error(chalk.name & ": replaceFileContents() called on an artifact that " &
          "isn't associated with a file.")
    return false

  # Need to close in order to successfully replace.
  closeFileStream(chalk.fsRef)

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
                  configPath: Option[string] = none(string),
                  usePath         = true,
                  ignoreChalkExes = false): Option[string] =
  var paths = extraPaths
  if configPath.isSome():
    # prepend on purpose so that config path
    # takes precedence over rest of dirs in PATH
    paths = @[configPath.get()] & paths

  trace("Searching PATH for " & cmdName)
  var foundExes = findAllExePaths(cmdName, paths, usePath)

  if ignoreChalkExes:
    var newExes: seq[string]

    startNativeCodecsOnly()

    for location in foundExes:
      let
        subscan   = runChalkSubScan(location, "extract")
        allChalks = subscan.getAllChalks()
        isChalk   = (
          len(allChalks) != 0 and
          allChalks[0].extract != nil and
         "$CHALK_IMPLEMENTATION_NAME" in allChalks[0].extract
        )
      if not isChalk:
        newExes.add(location)
        break

    endNativeCodecsOnly()

    foundExes = newExes

  if foundExes.len() == 0:
    trace("Could not find '" & cmdName & "' in PATH.")
    return none(string)

  trace("Found '" & cmdName & "' in PATH: " & foundExes[0])
  return some(foundExes[0])

proc handleExec*(prioritizedExes: seq[string], args: seq[string]) {.noreturn.} =
  for path in prioritizedExes:
    let cargs = allocCStringArray(@[path] & args)
    trace("execv: " & path & " " & args.join(" "))
    discard execv(cstring(path), cargs)
    # Either execv doesn't return, or something went wrong. No need to check the
    # error code.
    error("Chalk: when execing '" & path & "': " & $(strerror(errno)))

  error("Chalk: exec could not find a working executable to run.")
  quitChalk(1)

proc runCmdNoOutputCapture*(exe:       string,
                            args:      seq[string],
                            newStdIn = ""): int {.discardable.} =
  let execOutput = runCmdGetEverything(exe, args, newStdIn,
                                       passthrough = true)
  result = execOutput.getExit()

proc runCmdExitCode*(exe: string, args: seq[string]): int {.discardable } =
  let execOutput = runCmdGetEverything(exe, args,
                                       passthrough = false)
  result = execOutput.getExit()

type Redacted* = ref object
  raw:      string
  redacted: string

proc redact*(raw: string): Redacted =
  return Redacted(raw: raw, redacted: raw)

proc redact*(raw: string, redacted: string): Redacted =
  return Redacted(raw: raw, redacted: redacted)

proc redact*(data: seq[string]): seq[Redacted] =
  result = @[]
  for i in data:
    result.add(redact(i))

proc redacted*(data: seq[Redacted]): seq[string] =
  result = @[]
  for i in data:
    result.add(i.redacted)

proc raw*(data: seq[Redacted]): seq[string] =
  result = @[]
  for i in data:
    result.add(i.raw)

proc replaceItemWith*(data: seq[string], match: string, sub: string): seq[string] =
  result = @[]
  for i in data:
    if i == match:
      result.add(sub)
    else:
      result.add(i)

type EnvVar* = ref object
  name:     string
  value:    string
  previous: string
  exists:   bool

proc setEnv*(name: string, value: string): EnvVar =
  new result
  result.name     = name
  result.value    = value
  result.previous = getEnv(name)
  result.exists   = existsEnv(name)
  putEnv(name, value)

proc restore(env: EnvVar) =
  if not env.exists:
    delEnv(env.name)
  else:
    putEnv(env.name, env.previous)

proc restore(vars: seq[EnvVar]) =
  for env in vars:
    env.restore()

template withEnvRestore*(vars: seq[EnvVar], code: untyped) =
  try:
    code
  finally:
    vars.restore()

proc `$`*(vars: seq[EnvVar]): string =
  result = ""
  for env in vars:
    result &= env.name & "=" & env.value & " "

proc isInt*(i: string): bool =
  try:
    discard parseInt(i)
    return true
  except:
    return false

proc isUInt*(i: string): bool =
  try:
    discard parseUInt(i)
    return true
  except:
    return false

proc splitBy*(s: string, sep: string, default: string = ""): (string, string) =
  let parts = s.split(sep, maxsplit = 1)
  if len(parts) == 2:
    return (parts[0], parts[1])
  return (s, default)

proc rSplitBy*(s: string, sep: string, default: string = ""): (string, string) =
  let parts = s.rsplit(sep, maxsplit = 1)
  if len(parts) == 2:
    return (parts[0], parts[1])
  return (s, default)

proc removeSuffix*(s: string, suffix: string | char): string =
  # similar to strutil except it returns result back
  # vs in-place removal in stdlib
  result = s
  result.removeSuffix(suffix)

proc removePrefix*(s: string, prefix: string): string =
  # similar to strutil except it returns result back
  # vs in-place removal in stdlib
  result = s
  result.removePrefix(prefix)

proc `&`*(a: JsonNode, b: JsonNode): JsonNode =
  result = newJArray()
  for i in a.items():
    result.add(i)
  for i in b.items():
    result.add(i)

proc `&=`*(a: var JsonNode, b: JsonNode) =
  for i in b.items():
    a.add(i)

proc getStrElems*(node: JsonNode, default: seq[string] = @[]): seq[string] =
  result = @[]
  for i in node.getElems():
    result.add(i.getStr())
  if len(result) == 0:
    return default

proc toLowerKeysJsonNode*(node: JsonNode): JsonNode =
  ## Returns a new `JsonNode` that is identical to the given `node`
  ## except that every `JObject` key is lowercased.
  case node.kind:
  of JString:
    return node
  of JInt:
    return node
  of JFloat:
    return node
  of JBool:
    return node
  of JNull:
    return node
  of JObject:
    result = newJObject()
    for k, v in node.pairs():
      result[k.toLower()] = v.toLowerKeysJsonNode()
  of JArray:
    result = newJArray()
    for i in node.items():
      result.add(i.toLowerKeysJsonNode())

template withAtomicVar*[T](x: var T, code: untyped) =
  let copy = x.deepCopy()
  try:
    code
  except:
    # restore variable to original value
    x = copy
    raise

proc update*(self: ChalkDict, other: ChalkDict): ChalkDict {.discardable.} =
  result = self
  for k, v in other:
    self[k] = v

proc update*(self: JsonNode, other: JsonNode): JsonNode {.discardable.} =
  if self == nil:
    return other
  if other != nil:
    for k, v in other.pairs():
      self[k] = v
  return self

proc merge*(self: ChalkDict, other: ChalkDict, deep = false): ChalkDict {.discardable.} =
  result = self
  for k, v in other:
    if k in self and self[k].kind == MkSeq and v.kind == MkSeq:
      for i in v:
        if i notin self[k]:
          self[k].add(i)
    elif k in self and self[k].kind == MkTable and v.kind == MkTable:
      let
        mine   = unpack[ChalkDict](self[k])
        theirs = unpack[ChalkDict](v)
      if deep:
        mine.merge(theirs)
      else:
        for kk, vv in theirs:
          mine[kk] = vv
      self[k] = pack(mine)
    else:
      self[k] = v

proc nestWith*(self: ChalkDict, key: string): ChalkDict =
  result = ChalkDict()
  for k, v in self:
    let value = ChalkDict()
    value[key] = v
    result[k] = pack(value)

proc strip*(items: seq[string], leading = true, trailing = true, chars = Whitespace): seq[string] =
  result = @[]
  for i in items:
    result.add(i.strip(leading = leading, trailing = trailing, chars = chars))

proc makeExecutable*(path: string) =
  let
    existing = path.getFilePermissions()
    wanted   = existing + {fpUserExec, fpGroupExec, fpOthersExec}
  if existing != wanted:
    path.setFilePermissions(wanted)

proc getOrDefault*[T](self: openArray[T], i: int, default: T): T =
  if len(self) > i:
    return self[i]
  return default

proc getRelativePathBetween*(fromPath: string, toPath: string) : string =
  ## Given the `fromPath`, usually the project root, return the relative
  ## path of the file's `toPath`. Return nothing if its outside the project root,
  ## if `toPath` is an empty string or, if Dockerfile contents was passed via stdin.
  result = toPath.relativePath(fromPath)
  if result.startsWith("..") or result == "" or result.endsWith(stdinIndicator):
    trace("File is ephemeral or not contained within VCS project")
    return ""

proc update*(self: HttpHeaders, with: HttpHeaders): HttpHeaders =
  for k, v in with.pairs():
    self[k] = v
  return self

proc `+`*[T](a, b: OrderedSet[T]): OrderedSet[T] =
  result = initOrderedSet[T]()
  for i in a:
    result.incl(i)
  for i in b:
    result.incl(i)

proc toUnixInMs*(t: DateTime): int64 =
  let epoch = fromUnix(0).utc
  return (t - epoch).inMilliseconds()

proc forReport*(t: DateTime): DateTime =
  ## convert datetime to timezone for reporting chalk keys
  # eventually we might add a config to specify in which TZ to report in
  # however for now normalize to local timezone for reading report output
  return t.local

template withDuration*(c: untyped) =
  let start = getMonoTime()
  c
  let
    stop                = getMonoTime()
    diff                = stop - start
    duration {.inject.} = diff

proc seemsToBeUtf8*(stream: FileStream): bool =
  try:
    let s = stream.peekStr(256)
    # The below call returns the position of the first bad byte, or -1
    # if it *is* valid.
    if s.validateUtf8() != -1:
      return false
    else:
      return true
  except:
    return false
