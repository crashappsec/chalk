## The system plugin that runs LAST and deals with things that *must*
## come last, such as hashing, digital signatures, etc.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, strutils, nimSHA2, nimutils, con4m
import ../config, ../plugins, ../io/tobinary

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type MetsysPlugin* = ref object of Plugin

const
  callbackName    = "sign"
  callbackTypeStr = "f(string, string) -> (string, {string: string})"
let
  callbackType    = callbackTypeStr.toCon4mType()

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
      error("Found unknown key (" & k & ") in a SAMI we're replacing")
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

method getArtifactInfo*(self: MetsysPlugin,
                        sami: SamiObj): KeyInfo =

  new result

  let oldSamiOpt = config.getKeySpec("OLD_SAMI")

  if oldSamiOpt.isSome() and sami.primary.present and sami.primary.valid:
    let oldSamiSpec = oldSamiOpt.get()
    if not oldSamiSpec.getSkip():
      let oldpoint = sami.primary
      if oldpoint.samiFields.isSome():
        result["OLD_SAMI"] = processOldSami(sami, oldpoint.samiFields.get())

  if len(sami.err) != 0:
    result["ERR_INFO"] = pack(sami.err)

  let toHash = createdToBinary(sami)
  var shaCtx = initSHA[SHA256]()
  shaCtx.update(toHash)

  var
    metaHash     = shaCtx.final()
    ulidHiBytes  = metaHash[^10 .. ^9]
    ulidLowBytes = metaHash[^8 .. ^1]
    ulidHiInt    = (cast[ptr uint16](addr ulidHiBytes[0]))[]
    ulidLowInt   = (cast[ptr uint64](addr ulidLowBytes[0]))[]
    now          = unixTimeInMs()
    metaId       = encodeUlid(now, ulidHiInt, ulidLowInt)


  result["METADATA_HASH"] = pack(metahash.toHex().toLowerAscii())
  result["METADATA_ID"]   = pack(metaId)

  let optSigInfo = scall(getConfigState(),
                         callbackName,
                         @[sami.newFields["HASH"], pack(metaId)],
                         callbackType)

  if optSigInfo.isSome():
    let
      res  = optSigInfo.get()
      tup  = unpack[seq[Box]](res)
      hash = unpack[string](tup[0])

    if hash != "":
      result["SIGNATURE"]   = tup[0]
      result["SIGN_PARAMS"] = tup[1]

registerPlugin("metsys", MetsysPlugin())

registerCon4mCallback("sign", callbackTypeStr)
