##
## Copyright (c) 2023-2025, Crash Override, Inc.
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

import pkg/[
  con4m/st,
  nimutils/jwt,
]
import "."/[
  auth,
  chalkjson,
  config,
  docker/exe,
  normalize,
  reporting,
  run_management,
  sinks,
  types,
  utils/http,
  utils/json,
]

proc getChalkCommand(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getCommandName()))

proc getArgvLocal(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getArgs()))

proc getExeVersion(args: seq[Box], unused: ConfigState): Option[Box] =
  return some(pack(getChalkExeVersion()))

proc logBase(ll: string, args: seq[Box], s: ConfigState): Option[Box] =
  let
    msg      = unpack[string](args[0])
    color    = s.attrLookup("color")
    llevel   = s.attrLookup("log_level")

  # We probably don't need to check and set this every time. However,
  # the value CAN change across stacks.
  if color.isSome():
    setShowColor(unpack[bool](color.get()))
  if llevel.isSome():
    setLogLevel(unpack[string](llevel.get()))

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

proc isJwtValid(args: seq[Box], s: ConfigState): Option[Box] =
  let token = unpack[string](args[0])
  if len(token) == 0:
    return some(pack(false))
  try:
    let
      jwt     = parseJwtToken(token)
      isAlive = jwt.isStillAlive()
    # TODO validate full JWT structure
    return some(pack(isAlive))
  except:
    return some(pack(false))

proc authHeaders(args: seq[Box], s: ConfigState): Option[Box] =
  let
    name    = unpack[string](args[0])
    authOpt = getAuthConfigByName(name, attr=s.attrs)
    c4mHeaders  = newTable[string, string]()
  if authOpt.isNone():
    error("there is no auth config for: " & name)
  else:
    let
      auth        = authOpt.get()
      headers     = newHttpHeaders()
      authHeaders = auth.implementation.injectHeaders(auth, headers)
    for key, value in authHeaders.pairs():
      c4mHeaders[key] = value
  return some(pack(c4mHeaders))

const memoizeKey* = "$CHALK_MEMOIZE"

proc memoizeInChalkmark(args: seq[Box], s: ConfigState): Option[Box] =
  let
    name     = unpack[string](args[0])
    fn       = unpack[CallbackObj](args[1])
    existing = selfChalkGetSubKey(memoizeKey, name)
  if existing.isSome():
    return existing
  let valueOpt = s.sCall(fn, @[])
  if valueOpt.isNone():
    error("In memoize(\"" & name & "\", fn), fn didnt return any value")
    return none(Box)
  let value = valueOpt.get()
  selfChalkSetSubKey(memoizeKey, name, value)
  return valueOpt

proc c4mToJson(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let data = args[0]
  return some(pack(data.boxToJson()))

proc c4mParseJson(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    data = unpack[string](args[0])
  try:
    let
      json = parseJson(data)
      box  = nimJsonToBox(json)
    return some(box)
  except:
    error("Could not parse JSON: " & getCurrentExceptionMsg())
    return none(Box)

proc c4mParseJsonL(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let
    data = unpack[string](args[0])
  try:
    var json = newJArray()
    for line in data.strip().splitLines():
      json.add(parseJson(line))
    let box  = nimJsonToBox(json)
    return some(box)
  except:
    error("Could not parse JSON: " & getCurrentExceptionMsg())
    return none(Box)

proc c4mBinarySha256(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  let data = args[0]
  return some(pack(data.binEncodeItem().sha256Hex()))

proc dockerExe(args: seq[Box], unused = ConfigState(nil)): Option[Box] =
  return some(pack(getDockerExeLocation()))

proc canonicalizeTool(args: seq[Box], usued = ConfigState(nil)): Option[Box] =
  let
    tool = unpack[string](args[0])
    data = args[1]
  let callbackOpt = attrGetOpt[CallbackObj]("tool." & tool & ".canonicalize")
  if callbackOpt.isNone():
    trace(tool & ": no canonicalize()")
    return some(data)
  let callback = callbackOpt.get()
  trace(tool & ": canonicalizing with " & $callback)
  let canonicalized = runCallback(callback, @[data])
  if canonicalized.isNone():
    error(tool & ": missing implementation to canonicalize with " & $callback)
    return some(data)
  return canonicalized

proc copyReportTemplateKeys(args: seq[Box], c = ConfigState(nil)): Option[Box] =
  let
    copyFrom        = unpack[string](args[0])
    copyFromSection = "report_template." & copyFrom & ".key"
    copyTo          = unpack[string](args[1])
    copyToSection   = "report_template." & copyTo & ".key"

  if not sectionExists(c, copyFromSection):
    error(copyFrom & " report template does not exist. Cannot copy from it")
    return none(Box)

  if not sectionExists(c, copyToSection):
    con4mSectionCreate(c, copyToSection)

  let copyFromKeys = attrGetObject(c, copyFromSection).getContents()
  for k in copyFromKeys:
    if not sectionExists(c, copyToSection & "." & k):
      con4mSectionCreate(c, copyToSection & "." & k)
    let
      toUsePath = copyFromSection & "." & k & ".use"
      toUseOpt   = attrGetOpt[bool](toUsePath)
    if toUseOpt.isNone():
      error(toUsePath & ": is unkown. copy_report_template_keys() is used before that key is defined. skipping")
      continue
    con4mAttrSet(
      c,
      copyToSection & "." & k & ".use",
      pack(toUseOpt.get()),
      Con4mType(kind: TypeBool),
    )

  return none(Box)

let chalkCon4mBuiltins* = [
    ("version() -> string",
     BuiltInFn(getExeVersion),
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
     BuiltInFn(topicUnsubscribe),
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
     BuiltInFn(getArgvLocal),
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
     @["chalk"]),
    ("is_jwt_valid(string) -> bool",
     BuiltInFn(isJwtValid),
     """
Returns whether JWT token is valid and hasnt expired.
""",
     @["chalk"]),
    ("auth_headers(string) -> dict[string, string]",
     BuiltInFn(authHeaders),
     """
Returns auth headers for provided auth config.
""",
     @["chalk"]),
    ("memoize(string, func () -> string) -> string",
     BuiltInFn(memoizeInChalkmark),
     """
Memoizes function callback value in chalk mark for future lookups.

This way the function is only computed once.
""",
     @["chalk"]),

    ("parse_json(string) -> `x",
     BuiltInFn(c4mParseJson),
     """
Parses JSON string and returns data-struct back.
""",
     @["json"]),
    ("parse_jsonl(string) -> `x",
     BuiltInFn(c4mParseJsonL),
     """
Parses JSONl string and returns data-struct back.
""",
     @["json"]),
    ("to_json(`x) -> string",
     BuiltInFn(c4mToJson),
     """
Convert to JSON string.
""",
     @["json"]),
    ("binary_sha256(`x) -> string",
     BuiltInFn(c4mBinarySha256),
     """
Returns normalized binary hash of the data.
""",
     @["chalk"]),
     ("docker_exe() -> string",
      BuiltInFn(dockerExe),
      """
Find non-chalked docker executable path.
""",
      @["chalk"]),
     ("canonicalize_tool(string, `x) -> `x",
      BuiltInFn(canonicalizeTool),
      """
Canonicalize external tool output key.
""",
      @["chalk"]),
     ("copy_report_template_keys(string, string)",
      BuiltInFn(copyReportTemplateKeys),
      """
Copy existing reporting template keys to another reporting template.
""",
      @["chalk"]),
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

when not defined(release):
  discard subscribe("debug", defaultDebugHook)
