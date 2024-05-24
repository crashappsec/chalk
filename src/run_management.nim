##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common items related to managing the chalk run, including key
## setting, status stuff, and the core scan state ("collection
## contexts"), that the subscan module pushes and pops.

import std/[posix, monotimes, enumerate]
import "."/chalk_common
export chalk_common

var
  ctxStack            = seq[CollectionCtx](@[])
  collectionCtx       = CollectionCtx()
  startTime*          = getMonoTime().ticks()
  contextDirectories: seq[string]

proc get*[T](chalkConfig: ChalkConfig, fqn: string): T =
  get[T](chalkConfig.`@@attrscope@@`, fqn)

proc getOpt*[T](chalkConfig: ChalkConfig, fqn: string): Option[T] =
  getOpt[T](chalkConfig.`@@attrscope@@`, fqn)

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

template getNativeCodecsOnly*(): bool =
  nativeCodecsOnly

proc inSubscan*(): bool =
  return len(ctxStack) != 0

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
  if len(ctxStack) != 0:
    # pop from stack last item
    discard ctxStack.pop()
  # if there is previous item on stack
  # make it current collection context
  if len(ctxStack) != 0:
    collectionCtx = ctxStack[^1]
  else:
    collectionCtx = CollectionCtx()

proc setContextDirectories*(l: seq[string]) =
  # Used for 'where to look for stuff' plugins, particularly version control.
  if inSubscan():
    collectionCtx.contextDirectories = l
  else:
    contextDirectories = l

proc getContextDirectories*(): seq[string] =
  if inSubscan():
    return collectionCtx.contextDirectories
  return contextDirectories

proc getCurrentCollectionCtx*(): CollectionCtx =
  collectionCtx
proc getErrorObject*(): Option[ChalkObj] =
  collectionCtx.currentErrorObject
proc setErrorObject*(o: ChalkObj) =
  collectionCtx.currentErrorObject = some(o)
proc clearErrorObject*() =
  collectionCtx.currentErrorObject = none(ChalkObj)
proc getAllChalks*(): seq[ChalkObj] =
  collectionCtx.allChalks
proc getAllChalks*(cc: CollectionCtx): seq[ChalkObj] =
  cc.allChalks
proc addToAllChalks*(o: ChalkObj) =
  collectionCtx.allChalks.add(o)
proc setAllChalks*(s: seq[ChalkObj]) =
  collectionCtx.allChalks = s
proc removeFromAllChalks*(o: ChalkObj) =
  if o in collectionCtx.allChalks:
    # Note that this is NOT an order-preserving delete; it's O(1)
    collectionCtx.allChalks.del(collectionCtx.allChalks.find(o))
proc getUnmarked*(): seq[string] =
  collectionCtx.unmarked
proc addUnmarked*(s: string) =
  collectionCtx.unmarked.add(s)
proc isMarked*(chalk: ChalkObj): bool {.inline.} =
  return chalk.marked

proc newChalk*(name:         string            = "",
               chalkId:      string            = "",
               pid:          Option[Pid]       = none(Pid),
               fsRef:        string            = "",
               tag:          string            = "",
               repo:         string            = "",
               imageId:      string            = "",
               containerId:  string            = "",
               marked:       bool              = false,
               resourceType: set[ResourceType] = {ResourceFile},
               extract:      ChalkDict         = ChalkDict(nil),
               cache:        RootRef           = RootRef(nil),
               codec:        Plugin            = Plugin(nil),
               addToAllChalks                  = false): ChalkObj =

  result = ChalkObj(name:          name,
                    pid:           pid,
                    fsRef:         fsRef,
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

  if chalkId != "":
    result.collectedData["CHALK_ID"] = pack(chalkId)

  if extract != nil and len(extract) > 1:
    result.marked = true

  if addToAllChalks:
    result.addToAllChalks()

  setErrorObject(result)

template setIfNotEmpty*(dict: ChalkDict, key: string, val: string) =
  if val != "":
    dict[key] = pack(val)

template setIfNotEmpty*[T](dict: ChalkDict, key: string, val: seq[T]) =
  if len(val) > 0:
    dict[key] = pack[seq[T]](val)

template setFromEnvVar*(dict: ChalkDict, key: string, default: string = "") =
  dict.setIfNotEmpty(key, os.getEnv(key, default))

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
    when T is Box:
      d[k] = v
    else:
      d[k] = pack[T](v)

template setIfNeeded*[T](o: ChalkDict, k: string, v: T) =
  when T is string:
    if v != "":
      setIfSubscribed(o, k, v)
  elif T is seq or T is ChalkDict:
    if len(v) != 0:
      setIfSubscribed(o, k, v)
  elif T is Option:
    if v.isSome():
      setIfSubscribed(o, k, v.get())
  else:
    setIfSubscribed(o, k, v)

template setIfNeeded*[T](o: ChalkObj, k: string, v: T) =
  setIfNeeded(o.collectedData, k, v)

proc isChalkingOp*(): bool =
  return commandName in get[seq[string]](chalkConfig, "valid_chalk_command_names")

proc lookupByPath*(obj: ChalkDict, path: string): Option[Box] =
  let
    parts    = path.split(".")
    chalkKey = parts[0]
  if chalkKey notin obj:
    return none(Box)
  var value = obj
  for (i, p) in enumerate(parts[0..^1]):
    try:
      if i == len(parts) - 1:
        return some(value[p])
      else:
        value = unpack[ChalkDict](value[p])
    except:
      return none(Box)
  return none(Box)

proc lookupCollectedKey*(obj: ChalkObj, k: string): Option[Box] =
  if k in hostInfo:          return some(hostInfo[k])
  if k in obj.collectedData: return some(obj.collectedData[k])
  return none(Box)

proc setArgs*(a: seq[string]) =
  collectionCtx.args = a
proc getArgs*(): seq[string] = collectionCtx.args

var cmdSpec*: CommandSpec = nil
proc getArgCmdSpec*(): CommandSpec = cmdSpec

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

proc dockerTag*(chalk: ChalkObj, default = ""): string =
  if chalk.repo != "":
    let tag = if chalk.tag == "": "latest" else: chalk.tag
    return chalk.repo & ":" & tag
  return default
