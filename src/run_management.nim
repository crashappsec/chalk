##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common items related to managing the chalk run, including key
## setting, status stuff, and the core scan state ("collection
## contexts"), that the subscan module pushes and pops.

import chalk_common, posix, std/monotimes
export chalk_common

var
  ctxStack            = seq[CollectionCtx](@[])
  collectionCtx       = CollectionCtx()
  startTime*          = getMonoTime().ticks()


proc increfStream(chalk: ChalkObj) {.importc.}

# This is for when we're doing a `conf load`.  We force silence, turning off
# all logging of merit.
proc startTestRun*() =
  doingTestRun = true
proc endTestRun*()   =
  doingTestRun = false
proc startNativeCodecsOnly*() =
  nativeCodecsOnly = true
proc endNativeCodecsOnly*() =
  nativeCodecsOnly = false

template getNativeCodecsOnly*(): bool = nativeCodecsOnly

proc clearReportingState*() =
  startTime      = getMonoTime().ticks()
  ctxStack       = @[]
  collectionCtx  = CollectionCtx()
  hostInfo       = ChalkDict()
  subscribedKeys = Table[string, bool]()
  systemErrors   = @[]

proc pushCollectionCtx*(): CollectionCtx =
  ctxStack.add(collectionCtx)
  collectionCtx = CollectionCtx()
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
proc getAllChalks*(cc: CollectionCtx): seq[ChalkObj] = cc.allChalks
proc addToAllChalks*(o: ChalkObj) =
  collectionCtx.allChalks.add(o)
proc setAllChalks*(s: seq[ChalkObj]) =
  collectionCtx.allChalks = s
proc removeFromAllChalks*(o: ChalkObj) =
  if o in collectionCtx.allChalks:
    # Note that this is NOT an order-preserving delete; it's O(1)
    collectionCtx.allChalks.del(collectionCtx.allChalks.find(o))
proc getUnmarked*(): seq[string] = collectionCtx.unmarked
proc addUnmarked*(s: string) =
  collectionCtx.unmarked.add(s)
proc isMarked*(chalk: ChalkObj): bool {.inline.} = return chalk.marked

proc newChalk*(name:         string            = "",
               pid:          Option[Pid]       = none(Pid),
               fsRef:        string            = "",
               tag:          string            = "",
               repo:         string            = "",
               imageId:      string            = "",
               containerId:  string            = "",
               marked:       bool              = false,
               stream:       FileStream        = FileStream(nil),
               resourceType: set[ResourceType] = {ResourceFile},
               extract:      ChalkDict         = ChalkDict(nil),
               cache:        RootRef           = RootRef(nil),
               codec:        Plugin            = Plugin(nil),
               addToAllChalks                  = false): ChalkObj =

  result = ChalkObj(name:          name,
                    pid:           pid,
                    fsRef:         fsRef,
                    stream:        stream,
                    userRef:       tag,
                    repo:          repo,
                    marked:        marked,
                    imageId:       imageId,
                    containerId:   containerId,
                    collectedData: ChalkDict(),
                    opFailed:      false,
                    resourceType:  resourceType,
                    extract:       extract,
                    cache:         cache,
                    myCodec:       codec)

  if extract != nil and len(extract) > 1:
    result.marked = true


  if stream != FileStream(nil):
    result.increfStream()

  if addToAllChalks:
    result.addToAllChalks()

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

template isSubscribedKey*(key: string): bool =
  if key in subscribedKeys:
    subscribedKeys[key]
  else:
    false

template setIfSubscribed[T](d: ChalkDict, k: string, v: T) =
  if isSubscribedKey(k):
    d[k] = pack[T](v)

template setIfNeeded*[T](o: ChalkDict, k: string, v: T) =
  when T is string:
    if v != "":
      setIfSubscribed(o, k, v)
  elif T is seq or T is ChalkDict:
    if len(v) != 0:
      setIfSubscribed(o, k, v)
  else:
    setIfSubscribed(o, k, v)

template setIfNeeded*[T](o: ChalkObj, k: string, v: T) =
  setIfNeeded(o.collectedData, k, v)

proc isChalkingOp*(): bool =
  return commandName in chalkConfig.getValidChalkCommandNames()

proc lookupCollectedKey*(obj: ChalkObj, k: string): Option[Box] =
  if k in hostInfo:          return some(hostInfo[k])
  if k in obj.collectedData: return some(obj.collectedData[k])
  return none(Box)

proc setArgs*(a: seq[string]) =
  collectionCtx.args = a
proc getArgs*(): seq[string] = collectionCtx.args

var cmdSpec*: CommandSpec = nil
proc getArgCmdSpec*(): CommandSpec = cmdSpec

var contextDirectories: seq[string]

template setContextDirectories*(l: seq[string]) =
  # Used for 'where to look for stuff' plugins, particularly version control.
  contextDirectories = l

template getContextDirectories*(): seq[string] =
  contextDirectories

var hostCollectionSuspends = 0
template suspendHostCollection*() =         hostCollectionSuspends += 1
template restoreHostCollection*() =         hostCollectionSuspends -= 1
template hostCollectionSuspended*(): bool = hostCollectionSuspends != 0

proc persistInternalValues*(chalk: ChalkObj) =
  if chalk.extract == nil:
    return
  for item, value in chalk.extract:
    if item.startsWith("$"):
      chalk.collectedData[item] = value

proc makeNewValuesAvailable*(chalk: ChalkObj) =
  if chalk.extract == nil:
    chalk.extract = ChalkDict()
  for item, value in chalk.collectedData:
    if item.startsWith("$"):
      chalk.extract[item] = value
