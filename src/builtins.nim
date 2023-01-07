## This is where we keep builtin functions specific to SAMI, that do
## not belong in con4m.

import options
import tables
import json

import config
import nimutils/box
import con4m
import con4m/builtins

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

# getConfigState() is defined in config.nim, and basically
# just exports a variable that is auto-generated for us when we
# initialize con4m (also in config.nim).

proc packFilterRet*(s: string, b: bool): Option[Box] =
  var l: seq[Box] = @[]

  l.add(pack(s))
  l.add(pack(b))

  return some(pack(l))
  
proc debugEnabled*(args: seq[Box],
                   unused1: Con4mScope,
                   unused2: VarStack,
                   unused3: Con4mScope): Option[Box] =
  let output = unpack[string](args[0])
    
  when not defined(release):
    return packFilterRet(output, true)
  else:
    return packFilterRet("", false)

const llMap = { "required"  : logLevelNone,
                "none"      : logLevelNone,
                "error"     : logLevelErr,
                "warn"      : logLevelWarn,
                "info"      : logLevelVerbose,
                "trace"     : logLevelTrace}.toTable()

var   warnedAboutBadLL = false
const llDefault = "info" # reasonable default if a mistake is made.

proc logLevel*(args: seq[Box],
               unused1: Con4mScope,
               unused2: VarStack,
               unused3: Con4mScope): Option[Box] =
  
  let
    output      = unpack[string](args[0])
    actualLevel = unpack[int](args[1])
    targetLevel = unpack[string](args[2])
    ll          = if llMap.contains(targetLevel):
                    llMap[targetLevel]
                  else:
                    if not warnedAboutBadLL:
                      warn("Bad log level ' " & targetLevel &
                        "' provided in filter. Defaulting to '" &
                        llDefault & "'.")
                    llMap[llDefault] 

  if cast[LogLevel](actualLevel) <= ll:
    return packFilterRet(output, true)
  else:
    return packFilterRet("", false)

proc prettyJson*(args: seq[Box],
                 unused1: Con4mScope,
                 unused2: VarStack,
                 unused3: Con4mScope): Option[Box] =
    let output = unpack[string](args[0])

    try:
      return packFilterRet(pretty(parseJson(output)), true)
    except:
      return packFilterRet("\"Invalid JSon formatting\"", false)
  
proc loadAdditionalBuiltins*() =
  let
    ctx           = getConfigState()
    llsig         = "f(string, int, string)->(string, bool)"
    basefiltersig = "f(string, int)->(string, bool)"
    
  ctx.newBuiltIn("injecting", getInjecting, "f() -> bool")
  ctx.newBuiltIn("logLevel", logLevel, llsig)
  ctx.newBuiltIn("debugEnabled", debugEnabled, basefiltersig)
  ctx.newBuiltIn("prettyJson", prettyJson, basefiltersig)
  

