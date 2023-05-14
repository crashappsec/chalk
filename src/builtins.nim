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

import config, streams, options, tables, std/tempfiles, os

proc modedFileSinkOut(msg: string, cfg: SinkConfig, t: StringTable): bool =
  try:
    var stream = cast[FileStream](cfg.private)
    stream.write(msg)
    info("Wrote to file: " & cfg.config["filename"])
    return true
  except:
    once:
      # Let's not get too spammy here.  This will not error once per
      # file, but it's better than spam.
      error("Unable to write to file: " & cfg.config["filename"])
      dumpExOnDebug()

    return false

allSinks["file"].outputFunction = OutputCallback(modedFileSinkOut)

proc truncatingLog(msg: string, cfg: SinkConfig, t: StringTable): bool =
  let
    maxSize   = int(chalkConfig.reportCacheSize)
    truncSize =  maxSize shr 2    # 25%
    filename  = resolvePath(cfg.config["filename"])
  var f       = newFileStream(filename, mode = fmAppend)

  try:
    if f == nil:
      f = newFileStream(filename, mode = fmWrite)
      if f == nil:
        error(filename & ": cannot create log file (permissions issue?)")
        return
    f.write(msg & "\n")
    let loc = f.getPosition()
    f.close()
    if loc > maxSize:
      var
        oldf             = newFileStream(fileName, fmRead)
        (newfptr, path)  = createTempFile(tmpFilePrefix, tmpFileSuffix)
        newf             = newFileStream(newfptr)

      while oldf.getPosition() < truncSize:
        discard oldf.readLine()

      while oldf.getPosition() < loc:
        newf.writeLine(oldf.readLine())

      oldf.close()
      newf.close()
      moveFile(path, fileName)
  except:
    error(fileName & ": error truncating file: " & getCurrentExceptionMsg())
    dumpExOnDebug()

let conf = SinkRecord(outputFunction: truncatingLog,
                      keys:           {"filename" : true}.toTable())

registerSink("rotating_log", conf)


var args: seq[string]

proc setArgs*(a: seq[string]) =
  args = a

proc getArgs*(): seq[string] = args

proc getArgv(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getArgs()))

proc getExeName(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getCommandName()))

proc getExeVersion(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getChalkExeVersion()))

proc topicSubscribe*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
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
  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getSinkConfigByName(config)

  if `rec?`.isNone(): return some(pack(false))

  return some(pack(unsubscribe(topic, `rec?`.get())))

proc chalkErrSink(msg: string, cfg: SinkConfig, arg: StringTable): bool =
  result = true
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
  return logBase("error", args, s)

proc logWarn(args: seq[Box], s: ConfigState): Option[Box] =
  return logBase("warn", args, s)

proc logInfo(args: seq[Box], s: ConfigState): Option[Box] =
  return logBase("info", args, s)

proc logTrace(args: seq[Box], s: ConfigState): Option[Box] =
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
    ("argv0() -> string",                   BuiltInFn(getExeName)) ]

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
discard registerTopic("chalk_usage_stats")


when not defined(release): discard subscribe("debug", defaultDebugHook)
