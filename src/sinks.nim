##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Chalk-specific setup and APIs around nimtuils' IO sinks.

import uri, config

proc chalkLogWrap(msg: string, extra: StringTable) : (string, bool) =
  return (msg, true)

proc githubLogGroup(msg: string, extra: StringTable): (string, bool) =
  # https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#example-grouping-log-lines
  let
    header = "::group::Chalk Report"
    footer = "::endgroup::"
  var
    message = msg
  message.stripLineEnd() # in-place strip
  return (@[header, message, footer].join("\n"), true)

const
  availableFilters = { "log_level"       : MsgFilter(logLevelFilter),
                       "log_prefix"      : MsgFilter(logPrefixFilter),
                       "pretty_json"     : MsgFilter(prettyJson),
                       "fix_new_line"    : MsgFilter(fixNewline),
                       "show_topic"      : MsgFilter(showTopic),
                       "wrap"            : MsgFilter(chalkLogWrap),
                       "github_log_group": MsgFilter(githubLogGroup),
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

var availableAuthConfigs: Table[string, AuthConfig]

# These are used by reportcache.nim
var   sinkErrors*: seq[SinkConfig] = @[]
const quietTopics* = ["chalk_usage_stats"]

template formatIo(cfg: SinkConfig, t: Topic, err: string, msg: string): string =
  var line = ""

  case cfg.mySink.name
  of "rotating_log", "file":
    if "actual_file" in cfg.params:
      line &= cfg.params["actual_file"] & ": "
  else:
    discard

  line &= err

  if msg != "":
    line &= ": " & msg

  line &= " (sink conf='" & cfg.name & "')"

  if chalkconfig.getLogLevel() == "trace":
    case cfg.mySink.name
    of "post", "presign":
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

  if chalkconfig.getLogLevel() in ["trace", "info"]:
    let
      attrRoot = chalkConfig.`@@attrscope@@`
      attrOpt  = attrRoot.getObjectOpt("sink_config." & cfg.name)
      attr     = attrOpt.getOrElse(nil)

    if attr != nil and errmsg == "Write":
      let msgOpt = getOpt[string](attr, "on_write_msg")
      if msgOpt.isSome():
        info(strutils.strip(msgOpt.get()))
    elif quiet:
      trace(toOut)
    else:
      info(toOut)

proc getAuthConfigByName*(name: string): Option[AuthConfig] =
  if name == "":
    return none(AuthConfig)

  if name in availableAuthConfigs:
    return some(availableAuthConfigs[name])

  let
    attrRoot = chalkConfig.`@@attrscope@@`
    attrs    = attrRoot.getObjectOpt("auth_config." & name).getOrElse(nil)
    opts     = OrderedTableRef[string, string]()

  if attrs == nil:
    error("auth_config." & name & " is referenced but its missing in the config")
    return none(AuthConfig)

  let authType = getOpt[string](attrs, "auth").getOrElse("")
  if authType == "":
    error("auth_config." & name & ".auth is required")
    return none(AuthConfig)

  let implementationOpt = getAuthImplementation(authType)
  if implementationOpt.isNone():
    error("there is no implementation for " & authType & " auth")
    return none(AuthConfig)

  for k, _ in attrs.contents:
    case k
    of "auth":
      continue
    else:
      let boxOpt = getOpt[Box](attrs, k)
      if boxOpt.isSome():
        opts[k]  = unpack[string](boxOpt.get())
      else:
        error("auth_config." & name & "." & k & " is missing")
        return none(AuthConfig)

  try:
    result = configAuth(implementationOpt.get(), name, some(opts))
  except:
    error("auth_config." & name & " is misconfigured: " & getCurrentExceptionMsg())
    return none(AuthConfig)

  if result.isSome():
    availableAuthConfigs[name] = result.get()

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
    authName:    string
    filterNames: seq[string]
    filters:     seq[MsgFilter] = @[]
    opts                        = OrderedTableRef[string, string]()
    enabled:     bool           = true
    priority:    int
    deleteList:  seq[string]

  for k, _ in attrs.contents:
    case k
    of "enabled":
      if not get[bool](attrs, k):
        error("Sink configuration '" & name & " is disabled.")
        enabled = false
    of "priority":
      priority    = getOpt[int](attrs, k).getOrElse(0)
    of "filters":
      filterNames = getOpt[seq[string]](attrs, k).getOrElse(@[])
    of "sink":
      sinkName    = getOpt[string](attrs, k).getOrElse("")
    of "auth":
      authName    = getOpt[string](attrs, k).getOrElse("")
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
    of "on_write_msg":
      discard
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
    of "filename":
      opts[k] = getOpt[string](attrs, k).getOrElse("")
      try:
        opts[k] = resolvePath(opts[k])
      except:
        warn(opts[k] & ": could not resolve sink filename. disabling sink")
        enabled = false
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
  of "post", "presign":
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

  let authOpt = getAuthConfigByName(authName)
  if authName != "" and authOpt.isNone():
    error("Sink " & sinkName & " requires auth " & authName & " which could not be loaded")
    return none(SinkConfig)

  result = configSink(theSinkOpt.get(),
                      name,
                      some(opts),
                      filters  = filters,
                      handler  = errCbOpt,
                      logger   = okCbOpt,
                      auth     = authOpt,
                      enabled  = enabled,
                      priority = priority)

  if result.isSome():
    availableSinkConfigs[name] = result.get()
    trace("Loaded sink config for '" & name & "'")
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

proc ioSetup*(bgColor = "darkslategray") =
  once:
    useCrashTheme()
    addDefaultSinks()
    addDefaultAuths()
