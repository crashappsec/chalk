## The system plugin that runs FIRST.  Though, there's not really much
## that HAD to happen first.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options
import nimutils, ../types, ../config, ../plugins, ../extract

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

type SystemPlugin* = ref object of Plugin

method getArtifactInfo*(self: SystemPlugin, obj:  ChalkObj): ChalkDict =

  result = newTable[string, Box]()

  result["_MAGIC"]             = pack(magicUTF8)
  result["INJECTOR_VERSION"]   = pack(getChalkExeVersion())
  result["INJECTOR_PLATFORM"]  = pack(getChalkPlatform())
  result["INJECTOR_COMMIT_ID"] = pack(getChalkCommitID())

  let selfIdOpt = getSelfId()

  if selfIdOpt.isSome(): result["INJECTOR_ID"] = pack(selfIdOpt.get())

  let
    spec = config.getKeySpec("_CHALK_CONFIG").get()
    optVal = spec.getValue()

  if optVal.isSome(): result["_CHALK_CONFIG"] = optVal.get()

registerPlugin("system", SystemPlugin())
