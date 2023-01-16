import options, tables
import nimutils/box, con4m/[eval, st, builtins], ../config, ../plugins

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

registerPlugin("sbom_callback", SbomCallbackPlugin())
getConfigState().newCallback("get_sboms", callbackType)
