import tables, options, nimutils, ../config, ../plugins, formatstr

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type ConfFilePlugin* = ref object of Plugin

method getArtifactInfo*(self: ConfFilePlugin,
                        sami: SamiObj): KeyInfo =
  result = newTable[string, Box]()

  let
    keyList = getAllKeys()
    samiID  = unpack[int](sami.newFields["SAMI_ID"])
      
  for key in keyList:
    let
      spec   = config.getKeySpec(key).get()
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
      try:
        result[key] = pack(format(raw,
                                  { "artifactid":   $(samiId),
                                    "artifactname": intToWords(samiId, false)
                                  }))
      except:
        result[key] = pack(raw)
    else:
      result[key]   = optval.get()


registerPlugin("conffile", ConfFilePlugin())
