## This plugin uses information from the config file to set metadata
## keys.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, strutils, ../plugins, ../config

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

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
      let cbOpt = ctxChalkConf.sCall(v.callback.get(), args)
      if cbOpt.isSome(): result[k] = cbOpt.get()

method getHostInfo*(self: ConfFilePlugin,
                    p:    seq[string],
                    ins:  bool): ChalkDict =
  if not ins: return ChalkDict(nil)  # No callbacks
  return scanForWork(KtChalkableHost, none(ChalkObj), @[pack(p.join(":"))])

method getChalkInfo*(self: ConfFilePlugin, obj: ChalkObj): ChalkDict =
  return scanForWork(KtChalk, some(obj), @[pack(obj.fullpath)])

method getPostChalkInfo*(self: ConfFilePlugin,
                         obj:  ChalkObj,
                         ins:  bool): ChalkDict =
  return scanForWork(KtNonChalk, some(obj), @[pack(obj.fullpath)])


method getPostRunInfo*(self: ConfFilePlugin, objs: seq[ChalkObj]): ChalkDict =
  return scanForWork(KtHostOnly, none(ChalkObj), @[pack("")])

registerPlugin("conffile", ConfFilePlugin())
