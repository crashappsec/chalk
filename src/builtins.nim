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

import config, streams, options, tables, strformat, uri, types
import nimutils, con4m

discard subscribe(con4mTopic, defaultCon4mHook)

const
  customSinkType    = "f(string, {string : string}) -> bool"
  sinkConfSigShort  = "f(string, string, {string : string})"
  sinkConfSigLong   = "f(string, string, {string : string}, [string])"

proc modedFileSinkOut*(msg: string, cfg: SinkConfig, t: StringTable): bool =
  try:
    var stream = cast[FileStream](cfg.private)
    stream.write(msg)
    info("Wrote to file: " & cfg.config["filename"])
    return true
  except:
    return false

allSinks["file"].outputFunction = OutputCallback(modedFileSinkOut)

proc customOut(msg: string, record: SinkConfig, xtra: StringTable): bool =
  var
    cfg:  StringTable = newOrderedTable[string, string]()
    args: seq[Box]
    t:    Con4mType   = toCon4mType(customSinkType)

  for key, val in xtra:          cfg[key] = val
  for key, val in record.config: cfg[key] = val

  args.add(pack(msg))
  args.add(pack(cfg))

  var retBox = runCallback(ctxChalkConf, "outhook", args, some(t)).get()
  return unpack[bool](retBox)

const customKeys = { "secret" :  false, "uid"    : false, "filename": false,
                     "uri" :     false, "region" : false, "headers":  false,
                     "cacheid" : false, "aux"    : false }.toTable()

registerSink("custom", SinkRecord(outputFunction: customOut, keys: customKeys))
registerCon4mCallback("outhook", customSinkType)

const
  availableFilters = { "log_level"     : MsgFilter(logLevelFilter),
                       "log_prefix"    : MsgFilter(logPrefixFilter),
                       "pretty_json"   : MsgFilter(prettyJson),
                       "fix_new_line"  : MsgFilter(fixNewline),
                       "add_topic"     : MsgFilter(addTopic),
                       "wrap"          : MsgFilter(wrapToWidth)
                     }.toTable()

var availableHooks = { "log_hook"     : defaultLogHook,
                       "con4m_hook"   : defaultCon4mHook
                     }.toTable()

when not defined(release):
  availableHooks["debug_hook"] = defaultDebugHook

proc getFilterByName*(name: string): Option[MsgFilter] =
  if name in availableFilters:
    return some(availableFilters[name])
  return none(MsgFilter)

proc getFilterName*(filter: MsgFilter): Option[string] =
  for name, f in availableFilters:
    if f == filter: return some(name)

proc getHookByName*(name: string): Option[SinkConfig] =
  if name in availableHooks:
    return some(availableHooks[name])

  return none(SinkConfig)

proc getSinkConfigs*(): Table[string, SinkConfig] =
  return availableHooks

var args: seq[string]

proc setArgs*(a: seq[string]) =
  args = a

proc getArgs*(): seq[string] = args

proc getArgv(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getArgs()))

proc getExeName(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getCommandName()))

proc topicSubscribe(args: seq[Box], unused: ConfigState): Option[Box] =
  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getHookByName(config)

  if `rec?`.isNone():
    return some(pack(false))

  let
    record   = `rec?`.get()
    `topic?` = subscribe(topic, record)

  if `topic?`.isNone():
    return some(pack(false))

  return some(pack(true))

proc topicUnsubscribe(args: seq[Box], unused: ConfigState): Option[Box] =
  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getHookByName(config)

  if `rec?`.isNone():
    return some(pack(false))

  return some(pack(unsubscribe(topic, `rec?`.get())))

var chalkStack: seq[ChalkObj] = @[]

proc pushTargetChalkForErrorMsgs*(s: ChalkObj) =
  chalkStack.add(s)

proc popTargetChalkForErrorMsgs*() =
  discard chalkStack.pop()

# This is private, not available from con4m.
proc chalkErrSink(msg: string, cfg: SinkConfig, arg: StringTable): bool =
  if len(chalkStack) == 0:
    return false
  if chalkStack[^1] == nil:
    chalkStack[^1].err = @[msg]
  else:
    chalkStack[^1].err.add(msg)
  return true

proc chalkErrFilter(msg: string, info: StringTable): (string, bool) =
  if len(chalkStack) > 0 and keyLogLevel in info:
    let llStr = info[keyLogLevel]

    if (llStr in toLogLevelMap) and
     (toLogLevelMap[llStr] <= toLogLevelMap[chalkConfig.getChalkLogLevel()]):
      return (msg, true)

  return ("", false)

let errSinkObj = SinkRecord(outputFunction: chalkErrSink)

registerSink("chalk-err-log", errSinkObj)

let errCfg = configSink(errSinkObj,
                        filters = @[MsgFilter(chalkErrFilter)]).get()

subscribe("logs", errCfg)

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

proc sinkConfigLong(args: seq[Box], unused: ConfigState): Option[Box] =
    let
      sinkconf   = unpack[string](args[0])
      sinkName   = unpack[string](args[1])
      sinkopts   = unpack[OrderedTableRef[string, string]](args[2])
      filters    = unpack[seq[string]](args[3])
      cfgopt     = getSinkConfig(sinkName)

    if cfgOpt.isNone():
      warn(fmt"When running sinkConfig for config named '{sinkconf}': " &
           fmt"no such sink named '{sinkname}'")
      return

    let sinkConfData = cfgopt.get()

    # Need to call info config.nim for now because we don't have perms
    # to check the fields and have not set up accessors.
    checkHooks(sinkname, sinkconf, sinkConfData, sinkopts)

    if sinkname == "s3":
      try:
        let dstUri = parseUri(sinkopts["uri"])
        if dstUri.scheme != "s3":
          warn(fmt"Sink config '{sinkconf}' requires a URI of " &
               "the form s3://bucket-name/object-path (skipped)")
      except:
          warn(fmt"Sink config '{sinkconf}' contains an invalid URI (skipped)")

    var filterObjs: seq[MsgFilter] = @[]
    for filter in filters:
      if filter notin availableFilters:
        warn(fmt"Invalid filter named '{filter}': skipping filter.")
      else:
        filterObjs.add(availableFilters[filter])
        trace(fmt"Config {sinkconf}: added filter '{filter}'")

    # We currently pass through unknown keys to make life easier for
    # new sink writers.
    let theSinkOpt = getSink(sinkname)

    if theSinkOpt.isNone():
      warn(fmt"Sink {sinkname} is configured, and the config file specs it, " &
           "but there is no implementation for that sink.")
      return

    let `cfg?` = configSink(theSinkOpt.get(), some(sinkopts), filterObjs)

    if `cfg?`.isSome():
      availableHooks[sinkconf] = `cfg?`.get()
    else:
      warn(fmt"Output sink configuration '{sinkconf}' failed to load.")

proc sinkConfigShort(args: seq[Box], unused: ConfigState): Option[Box] =
  var a2 = args
  a2.add(pack[seq[string]](@[]))
  return sinkConfigLong(a2, unused)

proc getExeVersion(args: seq[Box], unused: ConfigState): Option[Box] =
    const retval = getChalkExeVersion()

    return some(pack(retval))

setChalkCon4mBuiltins(@[
  ("version",     BuiltinFn(getExeVersion),    "f() -> string"),
  ("subscribe",   BuiltInFn(topicSubscribe),   "f(string, string)->bool"),
  ("unsubscribe", BuiltInFn(topicUnSubscribe), "f(string, string)->bool"),
  ("error",       BuiltInFn(logError),         "f(string)"),
  ("warn",        BuiltInFn(logWarn),          "f(string)"),
  ("info",        BuiltInFn(logInfo),          "f(string)"),
  ("trace",       BuiltInFn(logTrace),         "f(string)"),
  ("argv",        BuiltInFn(getArgv),          "f() -> [string]"),
  ("argv0",       BuiltInFn(getExeName),       "f() -> string"),
  ("sink_config", BuiltInFn(sinkConfigShort),  sinkConfSigShort),
  ("sink_config", BuiltInFn(sinkConfigLong),   sinkConfSigLong)
  ])

# Can be used by codecs that aren't directly inserting.
discard registerTopic("ghost-insert")
discard registerTopic("extract")
discard registerTopic("insert")
discard registerTopic("replacing")
discard registerTopic("defaults")
discard registerTopic("dry-run")
discard registerTopic("delete")
discard registerTopic("audit")
discard registerTopic("confload")
discard registerTopic("confdump")
discard registerTopic("version")
discard registerTopic("help")

when not defined(release):
    discard subscribe("debug", defaultDebugHook)
