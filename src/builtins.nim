## This is where we keep builtin functions specific to SAMI, that do
## not belong in con4m.
import options, nimutils/[box, topics, logging]
import con4m, con4m/[builtins, st], config

# This "builtin" call for con4m doesn't need to be available until
# user configurations load, but let's be sure to do it before that
# happens.  First we define the function here, and next we'll register
# it.
var cmdInject = some(pack(false))

proc getInjecting*(args: seq[Box],
                   unused1: Con4mScope,
                   unused2: VarStack,
                   unused3: Con4mScope): Option[Box] =
    return cmdInject

proc topicSubscribe(args: seq[Box],
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

proc topicUnsubscribe(args: seq[Box],
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

proc logBuiltin(args: seq[Box],
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
    
proc loadAdditionalBuiltins*() =
  let ctx = getConfigState()
    
  ctx.newBuiltIn("injecting",   getInjecting,     "f() -> bool")
  ctx.newBuiltIn("subscribe",   topicSubscribe,   "f(string, string)->bool")
  ctx.newBuiltIn("unsubscribe", topicUnSubscribe, "f(string, string)->bool")
  ctx.newBuiltIn("log",         logBuiltin,       "f(string, string)")


