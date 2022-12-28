import ../types
import ../plugins
import ../config
import nimutils/box

import tables
import options

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

    result[key] = optval.get()


registerPlugin("conffile", ConfFilePlugin())
