import config, reporting, sinks, util

proc getChalkCommand(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getCommandName()))

proc getArgv(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getArgs()))

proc getExeVersion(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getChalkExeVersion()))

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

proc findExeC4m(args: seq[Box], s: ConfigState): Option[Box] =
  let
    cmdName    = unpack[string](args[0])
    extraPaths = unpack[seq[string]](args[1])

  return some(pack(findExePath(cmdName, extraPaths).getOrElse("")))

let chalkCon4mBuiltins* = [
    ("version() -> string",
     BuiltinFn(getExeVersion),
     "The current version of the chalk program.",
     @["chalk"]
    ),
    ("subscribe(string, string) -> bool",
     BuiltInFn(topicSubscribe),
     """
For the topic name given in the first parameter, subscribes the sink
configuration named in the second parameter.  The sink configuration
object must already be defined at the time of the call to subscribe()
""",
     @["chalk"]
    ),
    ("unsubscribe(string, string) -> bool",
     BuiltInFn(topicUnSubscribe),
     """
For the topic name given in the first parameter, unsubscribes the sink
configuration named in the second parameter, if subscribed.
""",
     @["chalk"]
    ),
    ("error(string)",
     BuiltInFn(logError),
     """
Immediately publishes a diagnostic message at log-level 'error'.  Whether this
gets delivered or not depends on the configuration.  Generally, errors will go
both to stderr, and be put in any published report.
""",
     @["chalk"]
    ),
    ("warn(string)",
     BuiltInFn(logWarn),
     """
Immediately publishes a diagnostic message at log-level 'warn'.  Whether this
gets delivered or not depends on the configuration.  Generally, warnings go to
stderr, unless wrapping the docker command, but do not get published to reports.
""",
     @["chalk"]
    ),
    ("info(string)",
     BuiltInFn(logInfo),
     """
Immediately publishes a diagnostic message at log-level 'info'.  Whether this
gets delivered or not depends on the configuration, but may be off by default.
""",
     @["chalk"]),
    ("trace(string)",
     BuiltInFn(logTrace),
     """
Immediately publishes a diagnostic message at log-level 'trace' (aka verbose).
Generally, these can get very noisy, and are intended more for testing,
 debugging, etc.
""",
     @["chalk"]),
    ("argv() -> list[string]",
     BuiltInFn(getArgv),
     """
Returns the arguments being passed to the command, such as the path
parameters.  This is not the same as the underlying process's argv; it
represents the arguments getting passed to the underlying chalk command.
""",
     @["chalk"]),
    ("argv0() -> string",
     BuiltInFn(getChalkCommand),
     """
Returns the name of the chalk command being run (not the underlying
executable name).
""",
     @["chalk"]),
     ("find_exe(string, list[string]) -> string",
     BuiltinFn(findExeC4m),
     """
Locate an executable with the given name in the PATH, adding any extra
directories passed in the second argument.
""",
     @["chalk"])
]

let errSinkObj = SinkImplementation(outputFunction: chalkErrSink)
registerSink("chalk-err-log", errSinkObj)
let errCfg = configSink(errSinkObj, "err-log-cfg",
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
