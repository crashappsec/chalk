import ../types
import ../plugins
import ../utils
import ../config

import con4m
import tables
import options

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type SystemPlugin* = ref object of Plugin

proc processOldSami(sami: SamiObj, olddict: SamiDict): Box =
  var groomedDict: SamiDict = newTable[string, Box]()

  for k, v in olddict:
    var fullkey = k
    var specOpt = getKeySpec(k)
    if specOpt.isNone():
      fullkey = k & ".json"
      specOpt = getKeySpec(fullkey)
      if specOpt.isNone():
        fullkey = k & ".binary"
        specOpt = getKeySpec(fullkey)

    if specOpt.isNone():
      warn("Found unknown key (" & k & ") in a SAMI we're replacing")
    else:
      let spec = specOpt.get()
      if spec.getSkip():
        continue
      if spec.getSquash():
        # The ones we're inserting now...
        if spec.getSystem() or sami.newFields.contains(k):
          continue
    groomedDict[fullkey] = v

  result = pack(groomedDict)


method getArtifactInfo*(self: SystemPlugin,
                        sami: SamiObj): KeyInfo =
  let samiId = cast[int](secureRand[uint64]()) and 0x7fffffffffffffff

  result = newTable[string, Box]()

  result["SAMI_ID"] = pack(samiId)
  result["TIMESTAMP"] = pack(cast[int](unixTimeInMs()))
  result["_MAGIC.json"] = pack("dadfedabbadabbed")

  let oldSamiOpt = config.getKeySpec("OLD_SAMI")

  if oldSamiOpt.isSome() and sami.primary.present and sami.primary.valid:
    let oldSamiSpec = oldSamiOpt.get()
    if not oldSamiSpec.getSkip():
      let oldpoint = sami.primary
      if oldpoint.samiFields.isSome():
        result["OLD_SAMI"] = processOldSami(sami, oldpoint.samiFields.get())

  # TODO... handle previous sami.

registerPlugin("system", SystemPlugin())
