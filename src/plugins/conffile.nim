## This plugin uses information from the config file to set metadata
## keys.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, nimutils, ../types, ../config, ../plugins, formatstr

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

type ConfFilePlugin* = ref object of Plugin

method getArtifactInfo*(self: ConfFilePlugin,
                        obj: ChalkObj): ChalkDict =
  result = newTable[string, Box]()

  let
    keyList = getAllKeys()
    chalkID = unpack[string](obj.newFields["CHALK_ID"])

  for key in keyList:
    let
      spec   = getKeySpec(key).get()
      optval = spec.getValue()

    if optval.isNone():  continue
    if spec.getSystem(): continue # This plugin doesn't handle system keys.

    if spec.getType() == "string":
      let raw = unpack[string](optval.get())
      if '\\' in raw:
        # This is a temporary fix for a bug in formatstr; I submitted
        # a patch, so when it makes it in, we can remove this branch.
        result[key] = pack(raw)
        continue
      try:     result[key] = pack(format(raw, { "artifactid":   chalkId}))
      except:  result[key] = pack(raw)
    else:
      result[key] = optval.get()


registerPlugin("conffile", ConfFilePlugin())
