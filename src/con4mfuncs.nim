##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Chalk-specific functions exposable via con4m.  Currently, this
## consists of a call to get the chalk version, and then API calls for
## our logging system.
##
## Though, it might be a decent thing to push the logging stuff into
## con4m at some point, as long as it's all optional.

import config, reporting, sinks

setLogLevelPrefix(llTrace, stylize("<jazzberry>trace: </jazzberry>").strip())

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


  # We probably don't need to check and set this every time. However,
  # the value CAN change across stacks.
  setShowColor(unpack[bool](color))
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
    ("command_argv() -> list[string]",
     BuiltInFn(getArgv),
     """
Returns the arguments being passed to the command, such as the path
parameters.  This is not the same as the underlying process's argv; it
represents the arguments getting passed to the underlying chalk command.
""",
     @["chalk"]),
    ("command_name() -> string",
     BuiltInFn(getChalkCommand),
     """
Returns the name of the chalk command being run (not the underlying
executable name).
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
