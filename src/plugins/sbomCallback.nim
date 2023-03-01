## A plugin providing a specific callback intended for having con4m
## collect SBOM information, most likely through an external command.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import options, tables
import nimutils/box, con4m/[eval, st], ../types, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

const pluginName      = "sbom_callback"
const callbackName    = "get_sboms"
const callbackTypeStr = "f(string) -> {string : string}"
let   callbackType    = callbackTypeStr.toCon4mType()

type SbomCallbackPlugin* = ref object of Plugin

method getArtifactInfo*(self: SbomCallbackPlugin, obj: ChalkObj): ChalkDict =

  let
    arg = @[pack(obj.fullpath)]
    optInfo = ctxChalkConf.sCall(callbackName, arg, callbackType)

  if optInfo.isSome():
    let
      res = optinfo.get()
      dict = unpack[TableRef[string, Box]](res)

    if len(dict) != 0:
      new result
      result["SBOMS"] = res

registerPlugin(pluginName, SbomCallbackPlugin())
registerCon4mCallback(callbackName, callbackTypeStr)
