import chalk_common
export chalk_common

var
  ctxStack            = seq[CollectionCtx](@[])
  collectionCtx       = CollectionCtx()
  `isChalkingOp?`:    bool

proc startTestRun*() =
  doingTestRun = true

proc endTestRun*() =
  doingTestRun = false

proc pushCollectionCtx*(callback: (CollectionCtx) -> void): CollectionCtx =
  ctxStack.add(collectionCtx)
  collectionCtx = CollectionCtx(postprocessor: callback)
  result        = collectionCtx

proc popCollectionCtx*() =
  if len(ctxStack) != 0: collectionCtx = ctxStack.pop()

proc inSubscan*(): bool =
  return len(ctxStack) != 0
proc getCurrentCollectionCtx*(): CollectionCtx = collectionCtx
proc getErrorObject*(): Option[ChalkObj] = collectionCtx.currentErrorObject
proc setErrorObject*(o: ChalkObj) =
  collectionCtx.currentErrorObject = some(o)
proc clearErrorObject*() =
  collectionCtx.currentErrorObject = none(ChalkObj)
proc getAllChalks*(): seq[ChalkObj] = collectionCtx.allChalks
proc addToAllChalks*(o: ChalkObj) =
  collectionCtx.allChalks.add(o)
proc setAllChalks*(s: seq[ChalkObj]) =
  collectionCtx.allChalks = s
proc removeFromAllChalks*(o: ChalkObj) =
  if o in collectionCtx.allChalks:
    collectionCtx.allChalks.del(collectionCtx.allChalks.find(o))
proc getUnmarked*(): seq[string] = collectionCtx.unmarked
proc addUnmarked*(s: string) =
  collectionCtx.unmarked.add(s)
proc isMarked*(chalk: ChalkObj): bool {.inline.} = return chalk.marked
proc newChalk*(stream: FileStream, loc: string): ChalkObj =
  result = ChalkObj(fullpath:      loc,
                    collectedData: ChalkDict(),
                    opFailed:      false,
                    stream:        stream,
                    extract:       nil)
  setErrorObject(result)

template setIfNotEmpty*(dict: ChalkDict, key: string, val: string) =
  if val != "":
    dict[key] = pack(val)

template setIfNotEmpty*[T](dict: ChalkDict, key: string, val: seq[T]) =
  if len(val) > 0:
    dict[key] = pack[seq[T]](val)

proc idFormat*(rawHash: string): string =
  let s = base32vEncode(rawHash)
  s[0 ..< 6] & "-" & s[6 ..< 10] & "-" & s[10 ..< 14] & "-" & s[14 ..< 20]

template hashFmt*(s: string): string =
  s.toHex().toLowerAscii()

template isSubscribedKey*(key: string): bool =
  if key in subscribedKeys:
    subscribedKeys[key]
  else:
    false

template setIfSubscribed*[T](d: ChalkDict, k: string, v: T) =
  if isSubscribedKey(k):
    d[k] = pack[T](v)

proc isChalkingOp*(): bool =
  once:
    `isChalkingOp?` = commandName in chalkConfig.getValidChalkCommandNames()
  return `isChalkingOp?`


proc lookupCollectedKey*(obj: ChalkObj, k: string): Option[Box] =
  if k in hostInfo:          return some(hostInfo[k])
  if k in obj.collectedData: return some(obj.collectedData[k])
  return none(Box)

var args: seq[string]

proc setArgs*(a: seq[string]) =
  args = a
proc getArgs*(): seq[string] = args

var cmdSpec*: CommandSpec = nil
proc getArgCmdSpec*(): CommandSpec = cmdSpec
