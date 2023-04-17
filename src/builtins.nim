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

import config, streams, options, tables, uri, std/tempfiles, os

proc modedFileSinkOut(msg: string, cfg: SinkConfig, t: StringTable): bool =
  try:
    var stream = cast[FileStream](cfg.private)
    stream.write(msg)
    info("Wrote to file: " & cfg.config["filename"])
    return true
  except:
    return false

allSinks["file"].outputFunction = OutputCallback(modedFileSinkOut)

proc truncatingLog(msg: string, cfg: SinkConfig, t: StringTable): bool =
  let
    maxSize   = int(chalkConfig.reportCacheSize)
    truncSize =  maxSize shr 2    # 25%
    filename  = resolvePath(cfg.config["filename"])
  var f       = newFileStream(filename, mode = fmAppend)

  try:
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

let conf = SinkRecord(outputFunction: truncatingLog,
                      keys:           {"filename" : true}.toTable())

register_sink("truncating_log", conf)

proc customOut(msg: string, record: SinkConfig, xtra: StringTable): bool =
  var
    cfg:  StringTable = newOrderedTable[string, string]()
    args: seq[Box]
    sig  = "outhook(string, dict[string, string]) -> bool"

  for key, val in xtra:          cfg[key] = val
  for key, val in record.config: cfg[key] = val

  args.add(pack(msg))
  args.add(pack(cfg))

  var retBox = runCallback(sig, args).get()
  return unpack[bool](retBox)

const customKeys = { "secret" :  false, "uid"    : false, "filename": false,
                     "uri" :     false, "region" : false, "headers":  false,
                     "cacheid" : false, "aux"    : false }.toTable()

registerSink("custom", SinkRecord(outputFunction: customOut, keys: customKeys))

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

when not defined(release): availableHooks["debug_hook"] = defaultDebugHook

proc getFilterName*(filter: MsgFilter): Option[string] =
  for name, f in availableFilters:
    if f == filter: return some(name)

proc getHookByName(name: string): Option[SinkConfig] =
  if name in availableHooks: return some(availableHooks[name])
  return none(SinkConfig)

proc getSinkConfigs*(): Table[string, SinkConfig] = return availableHooks

var args: seq[string]

proc setArgs*(a: seq[string]) =
  args = a

proc getArgs*(): seq[string] = args

proc getArgv(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getArgs()))

proc getExeName(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getCommandName()))

proc subscriptionExists(args: seq[Box], unused: ConfigState): Option[Box] =
  let
    config = unpack[string](args[0])
    `rec?` = getHookByName(config)

  return some(pack(`rec?`.isSome()))

proc topicSubscribe*(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    topic  = unpack[string](args[0])
    config = unpack[string](args[1])
    `rec?` = getHookByName(config)

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
    `rec?` = getHookByName(config)

  if `rec?`.isNone(): return some(pack(false))

  return some(pack(unsubscribe(topic, `rec?`.get())))

proc chalkErrSink(msg: string, cfg: SinkConfig, arg: StringTable): bool =
  result = true
  if not isChalkingOp() or currentErrorObject.isNone(): systemErrors.add(msg)
  else: currentErrorObject.get().err.add(msg)

proc chalkErrFilter(msg: string, info: StringTable): (string, bool) =
  if keyLogLevel in info:
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

var installed_sink_configs: seq[string] = @[]

proc sinkConfigLong(args: seq[Box], s: ConfigState): Option[Box] =
  let
    sinkConf   = unpack[string](args[0])
    sinkName   = unpack[string](args[1])
    sinkopts   = unpack[OrderedTableRef[string, string]](args[2])
    filters    = unpack[seq[string]](args[3])
    cfgopt     = getSinkConfig(sinkName)

  if cfgOpt.isNone():
    warn("When running sinkConfig for config named '" & sinkconf &
         "': no such sink named '" & sinkname & "'")
    return

  let sinkConfData = cfgopt.get()

  # Need to call info config.nim for now because we don't have perms
  # to check the fields and have not set up accessors.
  checkHooks(sinkname, sinkconf, sinkConfData, sinkopts)

  if sinkname == "s3":
    try:
      let dstUri = parseUri(sinkopts["uri"])
      if dstUri.scheme != "s3":
        warn("Sink config '" & sinkconf & "' requires a URI of " &
             "the form s3://bucket-name/object-path (skipped)")
    except:
        warn("Sink config '" & sinkconf & "' contains an invalid URI (skipped)")

  var filterObjs: seq[MsgFilter] = @[]
  for filter in filters:
    if filter notin availableFilters:
      warn("Invalid filter named '" & filter & "': skipping filter.")
    else:
      filterObjs.add(availableFilters[filter])
      trace("Config " & sinkconf & ": added filter '" & filter & "'")

  # We currently pass through unknown keys to make life easier for
  # new sink writers.
  let theSinkOpt = getSink(sinkname)

  if theSinkOpt.isNone():
    warn("Sink '" & sinkname & "' is configured, and the config file specs " &
         "it, but there is no implementation for that sink.")
    return

  let `cfg?` = configSink(theSinkOpt.get(), some(sinkopts), filterObjs)

  if `cfg?`.isSome():
    availableHooks[sinkconf] = `cfg?`.get()

    # Update what we've installed so validation can check whether custom
    # reports have proper sink specs attached to them.
    installed_sink_configs.add(sinkConf)
    discard attrSet(s.attrs,
                    "private_installed_sinks",
                    pack(installed_sink_configs))
  else:
    warn("Output sink configuration '" & sinkconf & "' failed to load.")

proc sinkConfigShort(args: seq[Box], unused: ConfigState): Option[Box] =
  var a2 = args
  a2.add(pack[seq[string]](@[]))
  return sinkConfigLong(a2, unused)

proc getExeVersion(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getChalkExeVersion()))

proc setupDefaultLogConfigs*() =
  let
    cacheFile = chalkConfig.getReportCacheLocation()
    doCache   = chalkConfig.getUseReportCache()
    auditFile = chalkConfig.getAuditLocation()
    doAudit   = chalkConfig.getPublishAudit()

  if doAudit and auditFile != "":
    let
      f         = some(newOrderedTable({ "filename" : auditFile}))
      auditConf = configSink(getSink("truncating_log").get(), f).get()

    availableHooks["audit_file"] = auditConf
    if subscribe("audit", auditConf).isNone():
      error("Unknown error initializing audit log.")
    else:
      trace("Audit log subscription enabled")
  if doCache:
    let
      f         = some(newOrderedTable({"filename" : cacheFile}))
      cacheConf = configSink(getSink("truncating_log").get(), f).get()

    availableHooks["report_cache"] = cacheConf
    if subscribe("report", cacheConf).isNone():
      error("Unknown error initializing report cache.")
    else:
      trace("Report cache subscription enabled")

  let
    uri       = chalkConfig.getCrashOverrideUsageReportingUrl()
    workspace = chalkConfig.getCrashOverrideWorkspaceId()
    headers   = "X-Crashoverride-Workspace-Id: " & workspace & "\n" &
                "Content-Type: application/json"

    params  = some(newOrderedTable({ "uri": uri, "headers" : headers }))
    useConf = configSink(getSink("post").get(), params)

  discard subscribe("chalk_usage_stats", useConf.get())

let
  scSigShort = "sink_config(string, string, dict[string, string])"
  scSigLong  = "sink_config(string, string, dict[string, string], list[string])"

let chalkCon4mBuiltins* = [
    ("version() -> string",                 BuiltinFn(getExeVersion)),
    ("subscribe(string, string) -> bool",   BuiltInFn(topicSubscribe)),
    ("unsubscribe(string, string) -> bool", BuiltInFn(topicUnSubscribe)),
    ("subscription_exists(string) -> bool", BuiltInFn(subscriptionExists)),
    ("error(string)",                       BuiltInFn(logError)),
    ("warn(string)",                        BuiltInFn(logWarn)),
    ("info(string)",                        BuiltInFn(logInfo)),
    ("trace(string)",                       BuiltInFn(logTrace)),
    ("argv() -> list[string]",              BuiltInFn(getArgv)),
    ("argv0() -> string",                   BuiltInFn(getExeName)),
    (scSigShort,                            BuiltInFn(sinkConfigShort)),
    (scSigLong,                             BuiltInFn(sinkConfigLong)) ]

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
