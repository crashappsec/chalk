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
  ctxStack   = @[CollectionCtx()]
  startTime* = getMonoTime().ticks()

proc getChalkScope*(): AttrScope =
  con4mRuntime.configState.attrs

proc sectionExists*(s: string): bool =
  getChalkScope().getObjectOpt(s).isSome()

proc attrGet*[T](fqn: string): T =
  get[T](getChalkScope(), fqn)

proc attrGetOpt*[T](fqn: string): Option[T] =
  getOpt[T](getChalkScope(), fqn)

proc attrGetObject*(fqn: string): AttrScope =
  getObject(getChalkScope(), fqn)

iterator getChalkSubsections*(s: string): string =
  ## Walks the contents of the given chalk config section, and yields the
  ## names of the subsections.
  for k, v in attrGetObject(s).contents:
    if v.isA(AttrScope):
      yield k

proc con4mAttrSet*(ctx: ConfigState, fqn: string, value: Box) =
  ## Sets the value of the `fqn` attribute in `ctx.attrs` to `value`, raising
  ## `AssertionDefect` if unsuccessful.
  ##
  ## This proc must only be used if the attribute is already set. If the
  ## attribute isn't already set, use the other `con4mAttrSet` overload instead.
  doAssert attrSet(ctx, fqn, value).code == errOk

proc con4mAttrSet*(fqn: string, value: Box, attrType: Con4mType) =
  ## Sets the value of the `fqn` attribute to `value`, raising `AssertionDefect`
  ## if unsuccessful.
  ##
  ## This proc may be used if the attribute is not already set.
  doAssert attrSet(getChalkScope(), fqn, value, attrType).code == errOk

proc con4mSectionCreate*(fqn: string) =
  discard attrLookup(getChalkScope(), fqn.split('.'), ix = 0, op = vlSecDef)

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
  return len(ctxStack) > 1

proc clearReportingState*() =
  startTime      = getMonoTime().ticks()
  ctxStack       = @[CollectionCtx()]
  hostInfo       = ChalkDict()
  subscribedKeys = Table[string, bool]()
  systemErrors   = @[]
  failedKeys     = ChalkDict()

proc pushCollectionCtx*(): CollectionCtx =
  result = CollectionCtx()
  ctxStack.add(result)

proc popCollectionCtx*() =
  if not inSubscan():
    raise newException(IndexError, "Cannot pop collection context outside of subscan")
  # pop from stack last item
  discard ctxStack.pop()

template collectionCtx(): CollectionCtx =
  ctxStack[^1]

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
proc setContextDirectories*(l: seq[string]) =
  # Used for 'where to look for stuff' plugins, particularly version control.
  collectionCtx.contextDirectories = l
proc getContextDirectories*(): seq[string] =
  collectionCtx.contextDirectories

proc isMarked*(chalk: ChalkObj): bool {.inline.} =
  return chalk.marked

proc newChalk*(name:         string            = "",
               chalkId:      string            = "",
               pid:          Option[Pid]       = none(Pid),
               fsRef:        string            = "",
               imageId:      string            = "",
               imageDigest:  string            = "",
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
                    imageId:       imageId,
                    imageDigest:   imageDigest,
                    containerId:   containerId,
                    collectedData: ChalkDict(),
                    opFailed:      false,
                    resourceType:  resourceType,
                    extract:       extract,
                    cache:         cache,
                    myCodec:       codec,
                    failedKeys:    ChalkDict(),
                   )

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

template setIfSubscribed*[T](d: ChalkDict, k: string, v: T) =
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

template trySetIfNeeded*(o: ChalkDict, k: string, code: untyped) =
  try:
    o.setIfNeeded(k, code)
  except:
    trace("Could not set chalk key " & k & " due to: " & getCurrentExceptionMsg())

proc isChalkingOp*(): bool =
  return commandName in attrGet[seq[string]]("valid_chalk_command_names")

proc addFailedKey*(key: string, code: string, error: string, description: string) =
  let errObject = getErrorObject()
  var failure   = ChalkDict()
  failure["code"] = pack(code)
  failure["error"] = pack(error)
  failure["description"] = pack(description)
  if not isChalkingOp() or errObject.isNone():
    failedKeys[key] = pack(failure)
  else:
    errObject.get().failedKeys[key] = pack(failure)

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

var chalkCollectionSuspendedByPlugin = initTable[string, int]()
template suspendChalkCollectionFor*(p: string) =
  if p notin chalkCollectionSuspendedByPlugin:
    chalkCollectionSuspendedByPlugin[p] = 0
  chalkCollectionSuspendedByPlugin[p] += 1
template restoreChalkCollectionFor*(p: string) =
  chalkCollectionSuspendedByPlugin[p] -= 1
template chalkCollectionSuspendedFor*(p: string): bool =
  chalkCollectionSuspendedByPlugin.getOrDefault(p, 0) != 0

proc persistInternalValues*(chalk: ChalkObj) =
  if chalk.extract == nil:
    return
  for item, value in chalk.extract:
    if item.startsWith("$"):
      chalk.collectedData[item] = value

proc persistExtractedValues*(chalk: ChalkObj) =
  if chalk.extract == nil:
    return
  for item, value in chalk.extract:
    if item notin chalk.collectedData:
      chalk.collectedData[item] = value

proc makeNewValuesAvailable*(chalk: ChalkObj) =
  if chalk.extract == nil:
    chalk.extract = ChalkDict()
  for item, value in chalk.collectedData:
    if item.startsWith("$"):
      chalk.extract[item] = value

proc isChalked*(chalk: ChalkObj): bool =
  return chalk.extract != nil
