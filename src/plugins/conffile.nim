##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin uses information from the config file to set metadata
## keys.

import ".."/[
  config,
  plugin_api,
  run_management,
  types,
]

proc scanForWork(kt: auto, opt: Option[ChalkObj], args: seq[Box]): ChalkDict =
  result = ChalkDict()
  for k in getChalkSubsections("keyspec"):
    let v = "keyspec." & k
    if opt.isNone() and k in hostInfo:                continue
    if opt.isSome() and k in opt.get().collectedData: continue
    if attrGet[int](v & ".kind") != int(kt): continue
    if not isSubscribedKey(k):
      continue
    try:
      let valueOpt = attrGetOpt[Box](v & ".value")
      let callbackOpt = attrGetOpt[CallbackObj](v & ".callback")
      if valueOpt.isSome():
        result.setIfNeeded(k, valueOpt.get())
      elif callbackOpt.isSome():
        let cbOpt = runCallback(callbackOpt.get(), args)
        if cbOpt.isSome():
          result.setIfNeeded(k, cbOpt.get())
    except:
      error("conffile: " & k & " ignoring error: " & getCurrentExceptionMsg())

proc confGetChalkTimeHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  return scanForWork(KtChalkableHost, none(ChalkObj),
                     @[pack(getContextDirectories().join(":"))])

proc confGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
    ChalkDict {.cdecl.} =
  return scanForWork(KtChalk, some(obj), @[pack(obj.name)])

proc confGetRunTimeArtifactInfo*(self: Plugin,
                                 obj:  ChalkObj,
                                 ins:  bool): ChalkDict {.cdecl.} =
  return scanForWork(KtNonChalk, some(obj), @[pack(obj.name)])

proc confGetRunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
       ChalkDict {.cdecl.} =
  return scanForWork(KtHostOnly, none(ChalkObj), @[pack("")])

proc loadConfFile*() =
  newPlugin("conffile",
            ctHostCallback = ChalkTimeHostCb(confGetChalkTimeHostInfo),
            ctArtCallback  = ChalkTimeArtifactCb(confGetChalkTimeArtifactInfo),
            rtArtCallback  = RunTimeArtifactCb(confGetRunTimeArtifactInfo),
            rtHostCallback = RunTimeHostCb(confGetRunTimeHostInfo),
            isSystem       = true)
