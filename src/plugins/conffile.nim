## This plugin uses information from the config file to set metadata
## keys.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import ../config, ../plugin_api

proc scanForWork(kt: auto, opt: Option[ChalkObj], args: seq[Box]): ChalkDict =
  result = ChalkDict()
  for k, v in chalkConfig.keySpecs:
    if opt.isNone() and k in hostInfo:                continue
    if opt.isSome() and k in opt.get().collectedData: continue
    if v.kind != int(kt): continue
    if k notin subscribedKeys: continue
    if v.value.isSome():
      result[k] = v.value.get()
    elif v.callback.isSome():
      let cbOpt = runCallback(v.callback.get(), args)
      if cbOpt.isSome(): result[k] = cbOpt.get()

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
            rtHostCallback = RunTimeHostCb(confGetRunTimeHostInfo))
