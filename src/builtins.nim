## This is where we keep our customizations of platform stuff that is
## specific to SAMI, including output setup and builtin con4m calls.
## That is, the output code and con4m calls here do not belong in
## con4m etc.

import config, streams, options, tables, strformat, uri
import nimutils, con4m

const customSinkType = "f(string, {string : string}) -> bool"

let ctxSamiConf = getConfigState()

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

  var retBox = runCallback(ctxSamiConf, "outhook", args, some(t)).get()
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

var availableHooks = { "log_hook"     : defaultLogHook
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

proc getArgv(args:    seq[Box],
             unused1: Con4mScope,
             unused2: VarStack,
             unused3: Con4mScope): Option[Box] =
  return some(pack(getArgs()))

proc getExeName(args:    seq[Box],
                unused1: Con4mScope,
                unused2: VarStack,
                unused3: Con4mScope): Option[Box] =
    return some(pack(getCommandName()))

proc topicSubscribe(args:    seq[Box],
                    unused1: Con4mScope,
                    unused2: VarStack,
                    unused3: Con4mScope): Option[Box] =
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

proc topicUnsubscribe(args:    seq[Box],
                      unused1: Con4mScope,
                      unused2: VarStack,
                      unused3: Con4mScope): Option[Box] =
    let
      topic  = unpack[string](args[0])
      config = unpack[string](args[1])
      `rec?` = getHookByName(config)

    if `rec?`.isNone():
      return some(pack(false))

    return some(pack(unsubscribe(topic, `rec?`.get())))

proc logBuiltin(args:    seq[Box],
                globals: Con4mScope,
                unused1: VarStack,
                unused2: Con4mScope): Option[Box] =
    let
      ll       = unpack[string](args[0])
      msg      = unpack[string](args[1])
      csym     = lookup(globals, "color").get()
      cval     = csym.value.get()
      `cover?` = csym.override
      lsym     = lookup(globals, "log_level").get()
      lval     = lsym.value.get()
      `lover?` = lsym.override

    # log level and color may have been set; con4m doesn't set that
    # stuff where we can see it until it ends evaluation.
    # TODO: add a simpler interface to con4m for this logic.

    if `cover?`.isSome():
      setShowColors(unpack[bool](`cover?`.get()))
    else:
      setShowColors(unpack[bool](cval))
    if `lover?`.isSome():
      setLogLevel(unpack[string](`lover?`.get()))
    else:
      setLogLevel(unpack[string](lval))

    log(ll, msg)

    return none(Box)

proc sinkConfig(args:    seq[Box],
                globals: Con4mScope,
                unused1: VarStack,
                unused2: Con4mScope): Option[Box] =
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

proc getOsName(args:    seq[Box],
               globals: Con4mScope,
               unused1: VarStack,
               unused2: Con4mScope): Option[Box] =
    const retval = getBinaryOS()

    return some(pack(retval))

proc getArch(args:    seq[Box],
             globals: Con4mScope,
             unused1: VarStack,
             unused2: Con4mScope): Option[Box] =
    const retval = getBinaryArch()

    return some(pack(retval))

proc getExeVersion(args:    seq[Box],
                   globals: Con4mScope,
                   unused1: VarStack,
                   unused2: Con4mScope): Option[Box] =
    const retval = getSamiExeVersion()

    return some(pack(retval))



setSamiCon4mBuiltins(@[
  ("osname",      BuiltInFn(getOsName),        "f() -> string"),
  ("arch",        BuiltInFn(getArch),          "f() -> string"),
  ("version",     BuiltinFn(getExeVersion),    "f() -> string"),
  ("subscribe",   BuiltInFn(topicSubscribe),   "f(string, string)->bool"),
  ("unsubscribe", BuiltInFn(topicUnSubscribe), "f(string, string)->bool"),
  ("log",         BuiltInFn(logBuiltin),       "f(string, string)"),
  ("argv",        BuiltInFn(getArgv),          "f() -> [string]"),
  ("argv0",       BuiltInFn(getExeName),       "f() -> string"),
  ("sink_config", BuiltInFn(sinkConfig),
                            "f(string, string, {string: string}, [string])")
  ])

discard registerTopic("extract")
discard registerTopic("insert")
discard registerTopic("nesting")
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
