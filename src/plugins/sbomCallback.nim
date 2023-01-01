import tables
import ../config
import ../plugins
import con4m/[eval, st, builtins]
import nimutils/box

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

const callbackType = "f(string) -> {string : string}"

type SbomCallbackPlugin* = ref object of Plugin
  
method getArtifactInfo*(self: SbomCallbackPlugin,
                        sami: SamiObj): KeyInfo =

  let optInfo = sCall(getConfigState(),
                      "get_sboms",
                      @[pack(sami.fullpath)],
                      callbackType.toCon4mType())
  if optInfo.isSome():
    let
      res = optinfo.get()
      dict = unpack[TableRef[string, Box]](res)
      
    if len(dict) != 0:
      new result
      result["SBOMS"] = res

registerPlugin("sbomCallback", SbomCallbackPlugin())
getConfigState().newCallback("get_sboms", callbackType)
