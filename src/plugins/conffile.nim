## This plugin uses information from the config file to set metadata
## keys.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import ../config

type ConfFilePlugin* = ref object of Plugin

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

method getChalkTimeHostInfo*(self: ConfFilePlugin,  p: seq[string]): ChalkDict =
  return scanForWork(KtChalkableHost, none(ChalkObj), @[pack(p.join(":"))])

method getChalkTimeArtifactInfo*(self: ConfFilePlugin, obj: ChalkObj):
       ChalkDict =
  return scanForWork(KtChalk, some(obj), @[pack(obj.fullpath)])

method getRunTimeArtifactInfo*(self: ConfFilePlugin,
                               obj:  ChalkObj,
                               ins:  bool): ChalkDict =
  return scanForWork(KtNonChalk, some(obj), @[pack(obj.fullpath)])


method getRunTimeHostInfo*(self: ConfFilePlugin, objs: seq[ChalkObj]):
       ChalkDict =
  return scanForWork(KtHostOnly, none(ChalkObj), @[pack("")])

registerPlugin("conffile", ConfFilePlugin())
