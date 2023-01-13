## This is where we keep our customizations of platform stuff that is
## specific to SAMI, including output setup and builtin con4m calls.
## That is, the output code and con4m calls here do not belong in
## con4m etc.

import tables, options, uri, strformat, nimutils, nimutils/logging, streams
import con4m, con4m/[builtins, st, eval], config

# This "builtin" call for con4m doesn't need to be available until
# user configurations load, but let's be sure to do it before that
# happens.  First we define the function here, and next we'll register
# it.
var cmdInject = some(pack(false))

# First builtin topic stuff.  Then builtin con4m calls.

discard registerTopic("extract")
discard registerTopic("inject")
discard registerTopic("nesting")
discard registerTopic("defaults")
discard registerTopic("dry-run")
discard registerTopic("delete")
discard registerTopic("confload")
discard registerTopic("confdump")
discard registerTopic("version")

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
ctxSamiConf.newCallback("outhook", customSinkType)

const
  availableFilters = { "logLevel"    : MsgFilter(logLevelFilter),
                       "logPrefix"   : MsgFilter(logPrefixFilter),
                       "prettyJson"  : MsgFilter(prettyJson),
                       "addTopic"    : MsgFilter(addTopic),
                       "wrap"        : MsgFilter(wrapToWidth)
                     }.toTable()

var availableHooks = { "debugHook" : defaultDebugHook,
                       "logHook"   : defaultLogHook
                     }.toTable()
  
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

proc getInjecting*(args: seq[Box],
                   unused1: Con4mScope,
                   unused2: VarStack,
                   unused3: Con4mScope): Option[Box] =
    return cmdInject

var args: seq[string]

proc setArgs*(a: seq[string]) =
  args = a

proc getArgs*(): seq[string] = args

var commandName: string

proc setCommandName*(str: string) =
  commandName = str
  
proc getArgv(args:    seq[Box],
             unused1: Con4mScope,
             unused2: VarStack,
             unused3: Con4mScope): Option[Box] =
  return some(pack(getArgs()))

proc getCommandName(args:    seq[Box],
                    unused1: Con4mScope,
                    unused2: VarStack,
                    unused3: Con4mScope): Option[Box] =
    return some(pack(commandName))
  
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
      sinkname   = unpack[string](args[1])
      sinkopts   = unpack[OrderedTableRef[string, string]](args[2])
      filters    = unpack[seq[string]](args[3])
      cfgopt     = getSinkConfig(sinkNAME)

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
        
    for filter in filters:
      if not getFilterByName(filter).isSome():
        warn(fmt"Invalid filter named '{filter}': skipping filter.")
    
    if sinkopts.contains("userid"):
      # Temporarily correct an oversight in the spec
      sinkopts["uid"] = sinkopts["userid"]  

    # We currently pass through unknown keys to make life easier for
    # new sink writers.

    var filterObjs: seq[MsgFilter] = @[]

    for item in filters:
      filterObjs.add(availableFilters[item])

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
    
proc loadAdditionalBuiltins*() =
  let ctx = getConfigState()

  ctx.newBuiltin("osname",      getOsName,        "f() -> string")
  ctx.newBuiltin("arch",        getArch,          "f() -> string")
  ctx.newBuiltin("version",     getExeVersion,    "f() -> string")
  ctx.newBuiltIn("injecting",   getInjecting,     "f() -> bool")
  ctx.newBuiltIn("subscribe",   topicSubscribe,   "f(string, string)->bool")
  ctx.newBuiltIn("unsubscribe", topicUnSubscribe, "f(string, string)->bool")
  ctx.newBuiltIn("log",         logBuiltin,       "f(string, string)")
  ctx.newBuiltIn("argv",        getArgv,          "f() -> [string]")
  ctx.newBuiltIn("argv0",       getCommandName,   "f() -> string")
  ctx.newBuiltIn("sinkConfig",  sinkConfig,
                 "f(string, string, {string: string}, [string])")

when not defined(release):
    discard subscribe("debug", defaultDebugHook)
