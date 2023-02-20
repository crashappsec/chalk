## The system plugin that runs LAST and deals with things that *must*
## come last, such as hashing, digital signatures, etc.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, strutils, nimSHA2, nimutils, con4m
import ../types, ../config, ../plugins, ../io/tobinary

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type MetsysPlugin* = ref object of Plugin

const
  callbackName    = "sign"
  callbackTypeStr = "f(string, string) -> (string, {string: string})"
let
  callbackType    = callbackTypeStr.toCon4mType()

proc processOldChalk(obj: ChalkObj, olddict: ChalkDict): Box =
  var groomedDict: ChalkDict = newTable[string, Box]()

  for k, v in olddict:
    var fullkey = k
    var specOpt = getKeySpec(k)

    if specOpt.isNone():
      error("Found unknown key (" & k & ") in a chalk object we're replacing")
    else:
      let spec = specOpt.get()
      if spec.getSkip():
        continue
      if spec.getSquash():
        # The ones we're inserting now...
        if spec.getSystem() or obj.newFields.contains(k):
          continue
    groomedDict[fullkey] = v

  result = pack(groomedDict)

method getArtifactInfo*(self: MetsysPlugin,
                        obj: ChalkObj): KeyInfo =

  new result

  let oldChalkOpt = config.getKeySpec("OLD_CHALK")

  if oldChalkOpt.isSome() and obj.primary.present and obj.primary.valid:
    let oldChalkSpec = oldChalkOpt.get()
    if not oldChalkSpec.getSkip():
      let oldpoint = obj.primary
      if oldpoint.chalkFields.isSome():
        result["OLD_CHALK"] = processOldChalk(obj, oldpoint.chalkFields.get())

  if len(obj.err) != 0:
    result["ERR_INFO"] = pack(obj.err)

  let toHash = createdToBinary(obj)
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

  let
    args       = @[obj.newFields["HASH"], pack(metaId)]
    optSigInfo = ctxChalkConf.sCall(callbackName, args, callbackType)

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
