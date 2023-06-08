## This is where we keep our customizations of platform stuff that is
## specific to chalk, including output setup and builtin con4m calls.
## That is, the output code and con4m calls here do not belong in
## con4m etc.
##
## Similarly, info about sinks and topics and other bits inherited
## from nimtuils are here.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import config, streams, options, tables, os, strutils, std/tempfiles

var doingTestRun = false

proc startTestRun*() =
  doingTestRun = true

proc endTestRun*() =
  doingTestRun = false

# This probably should move to nimutils next time I update it.
proc openLogFile*(name: string,
                  loc:  var string,
                  path: seq[string],
                  mode              = fmAppend): Option[FileStream] =
  ## Looks to open the given log file in the first possible place it
  ## can in the given path, even if it needs to create directories,
  ## etc.  If nothing in the path works, we try using a temp file as a
  ## last resort, using system APIs.
  ##
  ## The variable passed in as 'loc' will get the location we ended up
  ## selecting.
  ##
  ## Note that, if the 'name' parameter has a slash in it, we try that
  ## first, but if we can't open it, we try all our other options.
  ##
  ## Note that, if the mode is fmRead we position the steam at the
  ## beginning of the file.  For anything else, we jump to the end,
  ## even if you open for read/write.

  var
    fstream:  FileStream  = nil
    fullPath: seq[string] = path
    baseName: string      = name

  if '/' in name:
    let (head, tail) = splitPath(resolvePath(name))

    basename = tail
    fullPath = @[head] & fullPath

  for item in fullPath:
    try:
      let directory = resolvePath(item)
      createDir(directory)
      loc           = joinPath(directory, basename)
      fstream       = newFileStream(loc, mode)
      break
    except:
      continue

  if fstream == nil:
    try:
      let directory = createTempDir(basename, "tmpdir")
      loc           = joinPath(directory, basename)
      fstream       = newFileStream(loc, mode)
    except:
      return none(FileStream)

  # fmAppend will already position us at SEEK_END.  Nim doesn't have a
  # direct equivolent to seek() on file streams, we'd have to go down
  # to the posix API to so a seek(SEEK_END), so instead of picking
  # through the file stream internal state, we cheese it by discarding
  # a readAll().
  if mode notin [fmRead, fmAppend]:
    discard fstream.readAll()

  return some(fstream)

template cantLog() =
  var err = "Couldn't open a log file for sink configuration '" & confname &
    "'; requested file was: '" & cfg.config["filename"] & "'"

  if '/' in cfg.config["filename"]:
    err &= "Fallback search path: "
  else:
    err &= "Directories tried: "

  err &= logpath.join(", ")
  raise newException(IOError, err)

proc moddedFileSinkOut(msg: string, cfg: SinkConfig, t: StringTable) =
  var stream   = FileStream(cfg.private)
  let confname = cfg.getSinkConfigNameByObject().getOrElse("<unknown>")

  if stream == nil:
    var
      outloc:    string
      streamOpt: Option[FileStream]
      mode    = fmAppend
      logpath = chalkConfig.getLogSearchPath()

    if cfg.config.contains("mode") and cfg.config["mode"] == "w":
      mode = fmWrite

    streamOpt = openLogFile(cfg.config["filename"], outloc, logpath, mode)

    if streamOpt.isNone():
      # Sinks throw exceptions on failure; we will log this when caught.
      cantLog()

    info("Opened file: " & outloc & " (via sink config " & confname & ")")
    stream                    = streamOpt.get()
    cfg.config["actual_file"] = outloc
    cfg.private               = RootRef(stream)

  stream.write(msg)
  info("Wrote to log file: " & cfg.config["actual_file"] &
       " (via sink config " & confname & ")")

proc moddedRotoOut(msg: string, cfg: SinkConfig, t: StringTable) =
  var logState = LogSinkState(cfg.private)
  let confname = cfg.getSinkConfigNameByObject().getOrElse("<unknown>")

  if logState.stream == nil:
    var
      outloc:    string
      streamOpt: Option[FileStream]
      logpath = chalkConfig.getLogSearchPath()

    streamOpt = openLogFile(cfg.config["filename"], outloc, logpath)
    if streamOpt.isNone():
      cantLog()

    info("Opened file: " & outloc & " (via sink config " & confname & ")")
    logState.stream = streamOpt.get()
    cfg.config["actual_file"] = outloc

  # Even if no filter was added for \n we need to ensure the newline for
  # truncation boundaries.
  if msg[^1] != '\n':
    logState.stream.write(msg & '\n')
  else:
    logState.stream.write(msg)

  let loc = uint(logState.stream.getPosition())

  # If the message fills up the entire aloted space, we make an exception,
  # but the next message will def push it out.  The +1 is because we might
  # have written a newline above.
  if loc > logState.maxSize and logState.maxSize > uint(len(msg) + 1):
    let
      fullPath = cfg.config["actual_file"]
      truncLen = logState.maxSize shr 2  # Remove 25% of the file

    logState.stream.close() # "append" mode can't seek backward.
    let
      oldf            = newFileStream(fullPath, fmRead)
      (newfptr, path) = createTempFile("chalk", "log")
      newf            = newFileStream(newfptr)

    while oldf.getPosition() < int64(truncLen):
      discard oldf.readLine()

    while oldf.getPosition() < int64(loc):
      newf.writeLine(oldf.readLine())

    # Since we shrunk into a temp file that we're going to move over,
    # it's a lot easier to close the file and move it over.  If
    # another write happens to this sink config, then the file will
    # get re-opened next time.
    oldf.close()
    newf.close()
    moveFile(path, fullPath)
    logState.stream    = nil
    info("Wrote log then truncated by 25%: " & cfg.config["actual_file"] &
      " (via sink config " & confname & ")")
  else:
    info("Wrote to log file: " & cfg.config["actual_file"] &
      " (via sink config " & confname & ")")

allSinks["file"].outputFunction         = OutputCallback(moddedFileSinkOut)
allSinks["rotating_log"].outputFunction = OutputCallback(moddedRotoOut)

var args: seq[string]

proc setArgs*(a: seq[string]) =
  args = a

proc getArgs*(): seq[string] = args

proc getArgv(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getArgs()))

proc getChalkCommand(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getCommandName()))

proc getExeVersion(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getChalkExeVersion()))

proc topicSubscribe*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =

  if doingTestRun:
    return some(pack(true))

  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getSinkConfigByName(config)

  if `rec?`.isNone():
    error(config & ": unknown sink configuration")
    return some(pack(false))

  let
    record   = `rec?`.get()
    `topic?` = subscribe(topic, record)

  if `topic?`.isNone():
    error(topic & ": unknown topic")
    return some(pack(false))

  return some(pack(true))

proc topicUnsubscribe(args: seq[Box], unused: ConfigState): Option[Box] =
  if doingTestRun:
    return some(pack(true))

  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getSinkConfigByName(config)

  if `rec?`.isNone(): return some(pack(false))

  return some(pack(unsubscribe(topic, `rec?`.get())))

proc chalkErrSink(msg: string, cfg: SinkConfig, arg: StringTable) =
  let errObject = getErrorObject()
  if not isChalkingOp() or errObject.isNone(): systemErrors.add(msg)
  else: errObject.get().err.add(msg)

proc chalkErrFilter(msg: string, info: StringTable): (string, bool) =
  if not getSuspendLogging() and keyLogLevel in info:
    let llStr = info[keyLogLevel]

    if (llStr in toLogLevelMap) and chalkConfig != nil and
     (toLogLevelMap[llStr] <= toLogLevelMap[chalkConfig.getChalkLogLevel()]):
      return (msg, true)

  return ("", false)

proc logBase(ll: string, args: seq[Box], s: ConfigState): Option[Box] =
  let
    msg      = unpack[string](args[0])
    color    = s.attrLookup("color").get()
    llevel   = s.attrLookup("log_level").get()

  setShowColors(unpack[bool](color))
  setLogLevel(unpack[string](llevel))

  log(ll, msg)

  return none(Box)

proc logError(args: seq[Box], s: ConfigState): Option[Box] =
  if doingTestRun:
    return some(pack(true))

  return logBase("error", args, s)

proc logWarn(args: seq[Box], s: ConfigState): Option[Box] =
  if doingTestRun:
    return some(pack(true))

  return logBase("warn", args, s)

proc logInfo(args: seq[Box], s: ConfigState): Option[Box] =
  if doingTestRun:
    return some(pack(true))

  return logBase("info", args, s)

proc logTrace(args: seq[Box], s: ConfigState): Option[Box] =
  if doingTestRun:
    return some(pack(true))

  return logBase("trace", args, s)

let chalkCon4mBuiltins* = [
    ("version() -> string",                 BuiltinFn(getExeVersion)),
    ("subscribe(string, string) -> bool",   BuiltInFn(topicSubscribe)),
    ("unsubscribe(string, string) -> bool", BuiltInFn(topicUnSubscribe)),
    ("error(string)",                       BuiltInFn(logError)),
    ("warn(string)",                        BuiltInFn(logWarn)),
    ("info(string)",                        BuiltInFn(logInfo)),
    ("trace(string)",                       BuiltInFn(logTrace)),
    ("argv() -> list[string]",              BuiltInFn(getArgv)),
    ("argv0() -> string",                   BuiltInFn(getChalkCommand)) ]

let errSinkObj = SinkRecord(outputFunction: chalkErrSink)
registerSink("chalk-err-log", errSinkObj)
let errCfg = configSink(errSinkObj,
                        filters = @[MsgFilter(chalkErrFilter)]).get()
subscribe("logs", errCfg)
subscribe(con4mTopic, defaultCon4mHook)

discard registerTopic("report")    # Place(s) to send reporting.
discard registerTopic("defaults")  # Where to output config info to.
discard registerTopic("audit")     # Where to output audit info to.
discard registerTopic("version")   # Where to output version info.
discard registerTopic("help")      # Where to print help info.
discard registerTopic("confdump")  # Where to write out a config dump.
discard registerTopic("virtual")   # If 'virtual' chalking, where to write?
discard registerTopic("fail")      # This gets aborted reports that we
                                   # don't send by default, but might be
                                   # good telemetry for some people.
discard registerTopic("chalk_usage_stats")


when not defined(release): discard subscribe("debug", defaultDebugHook)
