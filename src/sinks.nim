##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Chalk-specific setup and APIs around nimtuils' IO sinks.

import std/[
  uri,
  posix,
]
import nimutils/[
  colortable,
]
import "."/[
  auth,
  config,
  run_management,
  types,
  utils/files,
  utils/json,
  utils/times,
]

proc chalkLogWrap(msg: string, extra: StringTable) : (string, bool) =
  return (msg, true)

proc chalkJsonLogs(msg: string, info: StringTable): (string, bool) =
  case attrGet[string]("log_format")
  of "auto":
    if getShowColor() or isInteractive:
      return (msg, true)
  of "plain":
    return (msg, true)
  let data = %*{
    "msg": msg,
    "chalk_version": getChalkExeVersion(),
    "chalk_commit": getChalkCommitId(),
    "chalk_magic": magicUTF8,
    "timestamp": getTime().utc.format(timesIso8601Format),
  }
  if keyLogLevel in info:
    data["log_level"] = %*info[keyLogLevel]
  return ($data, true)

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
  if inSubscan():
    return
  let errObject = getErrorObject()
  if not isChalkingOp() or errObject.isNone():
    systemErrors.add(msg)
  else:
    errObject.get().err.add(msg)

proc chalkErrFilter*(msg: string, info: StringTable): (string, bool) =
  if not getSuspendLogging() and keyLogLevel in info:
    let llStr = info[keyLogLevel]

    if (llStr in toLogLevelMap) and getChalkScope() != nil and
     (toLogLevelMap[llStr] <= toLogLevelMap[attrGet[string]("chalk_log_level")]):
      return (msg, true)

  return ("", false)

proc getFilterName*(filter: MsgFilter): Option[string] =
  for name, f in availableFilters:
    if f == filter: return some(name)

defaultLogHook.filters = @[MsgFilter(logLevelFilter),
                           MsgFilter(logPrefixFilter),
                           MsgFilter(chalkLogWrap),
                           MsgFilter(chalkJsonLogs)]

var availableSinkConfigs = { "log_hook"     : defaultLogHook,
                             "con4m_hook"   : defaultCon4mHook,
                     }.toTable()

when not defined(release):
  availableSinkConfigs["debug_hook"] = defaultDebugHook

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

  if attrGet[string]("log_level") == "trace":
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
      line &= "\n\turi                = " & cfg.params["uri"]
      line &= "\n\tcontent_type       = " & cfg.params["content_type"]
      line &= "\n\ttimeout            = " & timeout
      line &= "\n\theaders            = " & headers & "\n"
      line &= "\n\tpreferBundledCerts = " & cfg.params.getOrDefault("prefer_bundled_certs", "false") & "\n"
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

      if cfg.mySink.name != "file":
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

  if not quiet or attrGet[bool]("chalk_debug"):
    error(toOut)
  else:
    trace(toOut)
  if getChalkScope() != nil and attrGet[bool]("chalk_debug"):
    publish("debug", tb)

proc successHandler(cfg: SinkConfig, t: Topic, errmsg: string) =
  let quiet = t.name in quietTopics

  if quiet and not attrGet[bool]("chalk_debug"):
    return

  let toOut = formatIo(cfg, t, errmsg, "")

  if attrGet[string]("log_level") in ["trace", "info"]:
    let
      section  = "sink_config." & cfg.name

    if sectionExists(section) and errmsg == "Write":
      let msgOpt = attrGetOpt[string](section & ".on_write_msg")
      if msgOpt.isSome():
        info(strutils.strip(msgOpt.get()))
    elif quiet:
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
    section  = "sink_config." & name

  if not sectionExists(section):
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

  for k, _ in attrGetObject(section).contents:
    case k
    of "enabled":
      if not attrGet[bool](section & "." & k):
        error("Sink configuration '" & name & "' is disabled.")
        enabled = false
    of "priority":
      priority    = attrGetOpt[int](section & "." & k).getOrElse(0)
    of "filters":
      filterNames = attrGetOpt[seq[string]](section & "." & k).getOrElse(@[])
    of "sink":
      sinkName    = attrGetOpt[string](section & "." & k).getOrElse("")
    of "auth":
      authName    = attrGetOpt[string](section & "." & k).getOrElse("")
    of "use_search_path", "disallow_http", "prefer_bundled_certs":
      let boxOpt = attrGetOpt[Box](section & "." & k)
      if boxOpt.isSome():
        if boxOpt.get().kind != MkBool:
          error(k & " (sink config key) must be 'true' or 'false'")
        else:
          opts[k] = $(unpack[bool](boxOpt.get()))
    of "pinned_cert":
      let
        certContents = attrGetOpt[string](section & "." & k).getOrElse("")
        path         = writeNewTempFile(certContents, "pinned", ".pem")
      discard setOverride(getChalkScope(), section & ".pinned_cert_file", some(pack(path)))
      # Can't delete from a dict while we're iterating over it.
      deleteList.add(k)
    of "on_write_msg":
      discard
    of "log_search_path":
      let boxOpt = attrGetOpt[Box](section & "." & k)
      if boxOpt.isSome():
        try:
          let path = unpack[seq[string]](boxOpt.get())
          opts[k]  = path.join(":")  # Nimutils wants shell-like.
        except:
          error(k & " (sink config key) must be a list of string paths.")
    of "headers":
      let boxOpt = attrGetOpt[Box](section & "." & k)
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
      let boxOpt = attrGetOpt[Box](section & "." & k)
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
        let asInt = attrGetOpt[int64](section & "." & k).getOrElse(int64(10 * 1048576))
        opts[k] = $(asInt)
      except:
        error(k & " (sink config key) must be a size specification")
        continue
    of "filename":
      opts[k] = attrGetOpt[string](section & "." & k).getOrElse("")
      try:
        opts[k] = resolvePath(opts[k])
      except:
        warn(opts[k] & ": could not resolve sink filename. disabling sink")
        enabled = false
    else:
      opts[k] = attrGetOpt[string](section & "." & k).getOrElse("")

  for item in deleteList:
    attrGetObject(section).contents.del(item)

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
      opts["log_search_path"] = attrGet[seq[string]]("log_search_path").join(":")
  of "rotating_log":
    if "log_search_path" notin opts:
      opts["log_search_path"] = attrGet[seq[string]]("log_search_path").join(":")
  else:
    discard

  let theSinkOpt = getSinkImplementation(sinkName)
  if theSinkOpt.isNone():
    error("Sink '" & sinkName & "' is configured, and the config file " &
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
    auditFile = attrGet[string]("audit_location")
    doAudit   = attrGet[bool]("publish_audit")

  if doAudit and auditFile != "":
    let
      f         = some(newOrderedTable({ "filename" : auditFile,
                                         "max" :
                                         $(attrGet[Con4mSize]("audit_file_size"))}))
      sink      = getSinkImplementation("rotating_log").get()
      auditConf = configSink(sink, "audit", f, handler=errCbOpt,
                             logger=okCbOpt).get()

    availableSinkConfigs["audit_file"] = auditConf
    if subscribe("audit", auditConf).isNone():
      error("Unknown error initializing audit log.")
    else:
      trace("Audit log subscription enabled")
  let
    uri     = attrGet[string]("crashoverride_usage_reporting_url")
    params  = some(newOrderedTable({ "uri":                  uri,
                                     "content_type":         "application/json",
                                     "prefer_bundled_certs": "true",
                                     }))
    sink    = getSinkImplementation("post").get()
    useConf = configSink(sink, "usage_stats_conf", params, handler=errCbOpt,
                             logger=okCbOpt).get()

  discard subscribe("chalk_usage_stats", useConf)

proc ioSetup*(bgColor = "darkslategray") =
  once:
    useCrashTheme()
    addDefaultSinks()
    addDefaultAuths()
