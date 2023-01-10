import tables, options, nimutils, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type ConfFilePlugin* = ref object of Plugin

method getArtifactInfo*(self: ConfFilePlugin,
                        sami: SamiObj): KeyInfo =
  result = newTable[string, Box]()

  let keyList = getAllKeys()

  for key in keyList:
    let
      spec = config.getKeySpec(key).get()
      optval = spec.getValue()

    if optval.isNone(): continue
    if spec.getSystem(): continue # This plugin doesn't handle system keys.

    result[key] = optval.get()

registerPlugin("conffile", ConfFilePlugin())
