## Chalk-specific setup and APIs around nimtuils' IO sinks.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import uri, config

proc chalkLogWrap(msg: string, extra: StringTable) : (string, bool) =
  return (msg.perLineWrap(startingMaxLineWidth = -7,
                          firstHangingIndent = 7), true)

const
  availableFilters = { "log_level"     : MsgFilter(logLevelFilter),
                       "log_prefix"    : MsgFilter(logPrefixFilter),
                       "pretty_json"   : MsgFilter(prettyJson),
                       "fix_new_line"  : MsgFilter(fixNewline),
                       "add_topic"     : MsgFilter(addTopic),
                       "wrap"          : MsgFilter(chalkLogWrap)
                     }.toTable()

proc chalkErrSink*(msg: string, cfg: SinkConfig, t: Topic, arg: StringTable) =
  let errObject = getErrorObject()
  if not isChalkingOp() or errObject.isNone(): systemErrors.add(msg)
  else: errObject.get().err.add(msg)

proc chalkErrFilter*(msg: string, info: StringTable): (string, bool) =
  if not getSuspendLogging() and keyLogLevel in info:
    let llStr = info[keyLogLevel]

    if (llStr in toLogLevelMap) and chalkConfig != nil and
     (toLogLevelMap[llStr] <= toLogLevelMap[chalkConfig.getChalkLogLevel()]):
      return (msg, true)

  return ("", false)

proc getFilterName*(filter: MsgFilter): Option[string] =
  for name, f in availableFilters:
    if f == filter: return some(name)

defaultLogHook.filters = @[MsgFilter(logLevelFilter),
                           MsgFilter(logPrefixFilter),
                           MsgFilter(chalkLogWrap)]

var availableSinkConfigs = { "log_hook"     : defaultLogHook,
                             "con4m_hook"   : defaultCon4mHook,
                     }.toTable()

when not defined(release):
  availableSinkConfigs["debug_hook"] = defaultDebugHook

# These are used by reportcache.nim
var   sinkErrors*: seq[SinkConfig] = @[]
const quietTopics* = ["chalk_usage_stats"]

template formatIo(cfg: SinkConfig, t: Topic, err: string, msg: string): string =
  let base = "Publishing" & t.name & ": "
  var line = ""

  case cfg.mySink.name
  of "rotating_log", "file":
    line &= cfg.params["actual_file"] & ": "
  else:
    discard

  line &= err

  if msg != "":
    line &= ": " & msg

  line &= " (sink conf='" & cfg.name & "')"

  if chalkconfig.getLogLevel() == "trace":
    case cfg.mySink.name
    of "post":
      let
        timeout = if "timeout" in cfg.params:
                    cfg.params["timeout"] & " ms"
                  else:
                    "none"
        headers = if "headers" in cfg.params:
                    "\"\"\"\n" & cfg.params["headers"] & "\n\"\"\""
                  else:
                    "none"
      line &= "\n\turi          = " & cfg.params["uri"]
      line &= "\n\tcontent_type = " & cfg.params["content_type"]
      line &= "\n\ttimeout      = " & timeout
      line &= "\n\theaders      = " & headers & "\n"
    of "s3":
      let state = S3SinkState(cfg.private)
      line &= "\n\turi    = " & cfg.params["uri"]
      line &= "\n\tuid    = " & state.uid
      line &= "\n\tregion = " & state.region
      line &= "\n\textra  = "
      if state.extra == "":
        line &= "<not provided>\n"
      else:
        line &= state.extra & "\n"
    of "rotating_log", "file":
      let fname     = cfg.params["filename"]
      var log_parts = cfg.params["log_search_path"].split(":")

      for i in 0 ..< log_parts.len():
        log_parts[i] = log_parts[i].escapeJson()

      let log_path = "[" & log_parts.join(", ") & "]"

      line &= "\n\tfilename        = " & escapeJson(fname)
      line &= "\n\tlog_search_path = " & log_path

      if cfg.mysink.name != "file":
        let
          max      = cfg.params["max"]
          trunc    = if "truncation_amount" in cfg.params:
                       cfg.params["truncation_amount"]
                     else:
                       "25%"
        line &= "\n\tmax               = " & max
        line &= "\n\ttruncation_amount = " & trunc


    else:
      discard

  line

proc ioErrorHandler(cfg: SinkConfig, t: Topic, msg, err, tb: string) =
  let quiet = t.name in quietTopics
  if not quiet:
    sinkErrors.add(cfg)

  let
    toOut = formatIo(cfg, t, err, msg)

  if not quiet or chalkConfig.getChalkDebug():
    error(toOut)
  else:
    trace(toOut)
  if chalkConfig != nil and chalkConfig.getChalkDebug():
    publish("debug", tb)

proc successHandler(cfg: SinkConfig, t: Topic, errmsg: string) =
  let quiet = t.name in quietTopics

  if quiet and not chalkConfig.getChalkDebug():
    return

  let toOut = formatIo(cfg, t, errmsg, "")

  if quiet:
    trace(toOut)
  else:
    info(toOut)

var
  errCbOpt = some(FailCallback(ioErrorHandler))
  okCbOpt  = some(LogCallback(successHandler))


proc getSinkConfigByName*(name: string): Option[SinkConfig] =
  if name in availableSinkConfigs:
    return some(availableSinkConfigs[name])

  let
    attrRoot = chalkConfig.`@@attrscope@@`
    attrs    = attrRoot.getObjectOpt("sink_config." & name).getOrElse(nil)

  if attrs == nil:
    return none(SinkConfig)

  var
    sinkName:    string
    filterNames: seq[string]
    filters:     seq[MsgFilter] = @[]
    opts                        = OrderedTableRef[string, string]()
    deleteList:  seq[string]

  for k, _ in attrs.contents:
    case k
    of "enabled":
      if not get[bool](attrs, k):
        error("Sink configuration '" & name & " is disabled.")
        return none(SinkConfig)
    of "filters":
      filterNames = getOpt[seq[string]](attrs, k).getOrElse(@[])
    of "sink":
      sinkName    = getOpt[string](attrs, k).getOrElse("")
    of "use_search_path", "disallow_http":
      let boxOpt = getOpt[Box](attrs, k)
      if boxOpt.isSome():
        if boxOpt.get().kind != MkBool:
          error(k & " (sink config key) must be 'true' or 'false'")
        else:
          opts[k] = $(unpack[bool](boxOpt.get()))
    of "pinned_cert":
      let
        (stream, path) = getNewTempFile("pinned", ".pem")
        certContents   = getOpt[string](attrs, k).getOrElse("")

      stream.write(certContents)
      stream.close()
      discard attrs.setOverride("pinned_cert_file", some(pack(path)))
      # Can't delete from a dict while we're iterating over it.
      deleteList.add(k)

    of "log_search_path":
      let boxOpt = getOpt[Box](attrs, k)
      if boxOpt.isSome():
        try:
          let path = unpack[seq[string]](boxOpt.get())
          opts[k]  = path.join(":")  # Nimutils wants shell-like.
        except:
          error(k & " (sink config key) must be a list of string paths.")
    of "headers":
      let boxOpt = getOpt[Box](attrs, k)
      if boxOpt.isSome():
        try:
          let hdrs    = unpack[Con4mDict[string, string]](boxOpt.get())
          var content = ""
          for name, value in hdrs:
            content &= name & ": " & value & "\n"
          opts[k]  = content
        except:
          error(k & " (sink config key) must be a dict that map " &
                    "header names to values (which must be strings).")
    of "timeout", "truncation_amount":
      let boxOpt = getOpt[Box](attrs, k)
      if boxOpt.isSome():
        # TODO: move this check to the spec.
        if boxOpt.get().kind != MkInt:
          error(k & " (sink config key) must be an int value in miliseconds")
        else:
          # Nimutils wants this param as a string.
          opts[k] = $(unpack[int](boxOpt.get()))
    of "max":
      try:
        # Todo: move this check to a type check in the spec.
        # This will accept con4m size types; they're auto-converted to int.
        let asInt = getOpt[int64](attrs, k).getOrElse(int64(10 * 1048576))
        opts[k] = $(asInt)
      except:
        error(k & " (sink config key) must be a size specification")
        continue
    else:
      opts[k] = getOpt[string](attrs, k).getOrElse("")

  for item in deleteList:
    attrs.contents.del(item)

  case sinkName
  of "":
    error("Sink config '" & name & "' does not specify a sink type.")
    dumpExOnDebug()
    return none(SinkConfig)
  of "s3":
    try:
      let dstUri = parseUri(opts["uri"])
      if dstUri.scheme != "s3":
        error("Sink config '" & name & "' requires a URI of " &
              "the form s3://bucket-name/object-path")
        return none(SinkConfig)
    except:
        error("Sink config '" & name & "' has an invalid URI.")
        dumpExOnDebug()
        return none(SinkConfig)
  of "post":
    if "content_type" notin opts:
      opts["content_type"] = "application/json"
  of "file":
    if "log_search_path" notin opts:
      opts["log_search_path"] = chalkConfig.getLogSearchPath().join(":")
  of "rotating_log":
    if "log_search_path" notin opts:
      opts["log_search_path"] = chalkConfig.getLogSearchPath().join(":")
  else:
    discard

  let theSinkOpt = getSinkImplementation(sinkName)
  if theSinkOpt.isNone():
    error("Sink '" & sinkname & "' is configured, and the config file " &
         "specs it, but there is no implementation for that sink.")
    return none(SinkConfig)

  for item in filterNames:
    if item notin availableFilters:
      error("Message filter '" & item & "' cannot be found.")
    else:
     filters.add(availableFilters[item])

  result = configSink(theSinkOpt.get(), name, some(opts), filters,
                      errCbOpt, okCbOpt)

  if result.isSome():
    availableSinkConfigs[name] = result.get()
    info("Loaded sink config for '" & name & "'")
  else:
    error("Output sink configuration '" & name & "' failed to load.")
    return none(SinkConfig)

proc getSinkConfigs*(): Table[string, SinkConfig] = return availableSinkConfigs

proc setupDefaultLogConfigs*() =
  let
    auditFile = chalkConfig.getAuditLocation()
    doAudit   = chalkConfig.getPublishAudit()

  if doAudit and auditFile != "":
    let
      f         = some(newOrderedTable({ "filename" : auditFile,
                                         "max" :
                                         $(chalkConfig.getAuditFileSize())}))
      sink      = getSinkImplementation("rotating_log").get()
      auditConf = configSink(sink, "audit", f, handler=errCbOpt,
                             logger=okCbOpt).get()

    availableSinkConfigs["audit_file"] = auditConf
    if subscribe("audit", auditConf).isNone():
      error("Unknown error initializing audit log.")
    else:
      trace("Audit log subscription enabled")
  let
    uri     = chalkConfig.getCrashOverrideUsageReportingUrl()
    params  = some(newOrderedTable({ "uri":          uri,
                                     "content_type": "application/json" }))
    sink    = getSinkImplementation("post").get()
    useConf = configSink(sink, "usage_stats_conf", params, handler=errCbOpt,
                             logger=okCbOpt).get()

  discard subscribe("chalk_usage_stats", useConf)
