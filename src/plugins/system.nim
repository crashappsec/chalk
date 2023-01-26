import tables, options
import nimutils, ../config, ../plugins, ../extract

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type SystemPlugin* = ref object of Plugin

method getArtifactInfo*(self: SystemPlugin,
                        sami: SamiObj): KeyInfo =

  result = newTable[string, Box]()

  result["_MAGIC.json"]        = pack("dadfedabbadabbed")
  result["INJECTOR_VERSION"]   = pack(getSamiExeVersion())
  result["INJECTOR_PLATFORM"]  = pack(getSamiPlatform())
  result["INJECTOR_COMMIT_ID"] = pack(getSamiCommitID())

  let selfIdOpt = getSelfId()

  if selfIdOpt.isSome():
    result["INJECTOR_ID"] = pack(selfIdOpt.get())

  let
    spec = config.getKeySpec("X_SAMI_CONFIG").get()
    optVal = spec.getValue()

  if optVal.isSome():
    result["X_SAMI_CONFIG"] = optVal.get()


registerPlugin("system", SystemPlugin())
