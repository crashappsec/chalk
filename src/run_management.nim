##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common items related to managing the chalk run, including key
## setting, status stuff, and the core scan state ("collection
## contexts"), that the subscan module pushes and pops.

import std/[posix, monotimes, enumerate, times]
import "."/chalk_common
export chalk_common

var
  ctxStack       = @[CollectionCtx()]
  startTime*     = getTime().utc # gives absolute wall time
  monoStartTime* = getMonoTime() # used for computing diffs

proc getChalkConfigState(): ConfigState =
  con4mRuntime.configState

proc getChalkScope*(): AttrScope =
  getChalkConfigState().attrs

proc sectionExists*(c: ConfigState, s: string): bool =
  c.attrs.getObjectOpt(s).isSome()

proc sectionExists*(s: string): bool =
  sectionExists(getChalkConfigState(), s)

proc attrGet*[T](c: ConfigState, fqn: string): T =
  get[T](c.attrs, fqn)

proc attrGet*[T](fqn: string): T =
  attrGet[T](getChalkConfigState(), fqn)

proc attrGetOpt*[T](c: ConfigState, fqn: string): Option[T] =
  getOpt[T](c.attrs, fqn)

proc attrGetOpt*[T](fqn: string): Option[T] =
  attrGetOpt[T](getChalkConfigState(), fqn)

proc attrGetObject*(c: ConfigState, fqn: string): AttrScope =
  getObject(c.attrs, fqn)

proc attrGetObject*(fqn: string): AttrScope =
  attrGetObject(getChalkConfigState(), fqn)

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

proc con4mAttrSet*(c: ConfigState, fqn: string, value: Box, attrType: Con4mType) =
  ## Sets the value of the `fqn` attribute to `value`, raising `AssertionDefect`
  ## if unsuccessful.
  ##
  ## This proc may be used if the attribute is not already set.
  doAssert attrSet(c.attrs, fqn, value, attrType).code == errOk

proc con4mAttrSet*(fqn: string, value: Box, attrType: Con4mType) =
  ## Sets the value of the `fqn` attribute to `value`, raising `AssertionDefect`
  ## if unsuccessful.
  ##
  ## This proc may be used if the attribute is not already set.
  con4mAttrSet(getChalkConfigState(), fqn, value, attrType)

proc con4mSectionCreate*(c: ConfigState, fqn: string) =
  discard attrLookup(c.attrs, fqn.split('.'), ix = 0, op = vlSecDef)

proc con4mSectionCreate*(fqn: string) =
  con4mSectionCreate(con4mRuntime.configState, fqn)

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
  startTime       = getTime().utc
  monoStartTime   = getMonoTime()
  ctxStack        = @[CollectionCtx()]
  hostInfo        = ChalkDict()
  objectsData     = ObjectsDict()
  subscribedKeys  = Table[string, bool]()
  systemErrors    = @[]
  failedKeys      = ChalkDict()
  externalActions = @[]
  for name, plugin in installedPlugins.pairs():
    if plugin.clearState == nil:
      continue
    let cb = plugin.clearState
    cb(plugin)

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
proc getAllChalks*(): seq[ChalkObj] =
  collectionCtx.allChalks
proc getAllChalks*(cc: CollectionCtx): seq[ChalkObj] =
  cc.allChalks
proc addToAllChalks*(o: ChalkObj) =
  if o notin collectionCtx.allChalks:
    collectionCtx.allChalks.add(o)
proc setAllChalks*(s: seq[ChalkObj]) =
  collectionCtx.allChalks = s
proc removeFromAllChalks*(o: ChalkObj) =
  if o in collectionCtx.allChalks:
    # Note that this is NOT an order-preserving delete; it's O(1)
    collectionCtx.allChalks.del(collectionCtx.allChalks.find(o))
proc getAllArtifacts*(): seq[ChalkObj] =
  collectionCtx.allArtifacts
proc getAllArtifacts*(cc: CollectionCtx): seq[ChalkObj] =
  cc.allArtifacts
proc addToAllArtifacts*(o: ChalkObj) =
  if o notin collectionCtx.allArtifacts:
    collectionCtx.allArtifacts.add(o)
proc setAllArtifacts*(s: seq[ChalkObj]) =
  collectionCtx.allArtifacts = s
proc removeFromAllArtifacts*(o: ChalkObj) =
  if o in collectionCtx.allArtifacts:
    # Note that this is NOT an order-preserving delete; it's O(1)
    collectionCtx.allArtifacts.del(collectionCtx.allArtifacts.find(o))
proc getUnmarked*(): seq[string] =
  collectionCtx.unmarked
proc addUnmarked*(s: string) =
  if s notin collectionCtx.unmarked:
    collectionCtx.unmarked.add(s)
proc setContextDirectories*(l: seq[string]) =
  # Used for 'where to look for stuff' plugins, particularly version control.
  var dirs = newSeq[string]()
  for i in l:
    dirs.add(
      # if its a file, normalize to its parent folder
      # as the context should be a directory
      if i.fileExists():
        i.parentDir()
      else:
        i
    )
  collectionCtx.contextDirectories = dirs
proc getContextDirectories*(): seq[string] =
  collectionCtx.contextDirectories

template withErrorContext*(chalk: ChalkObj, c: untyped) =
  var previous = collectionCtx.currentErrorObject
  try:
    collectionCtx.currentErrorObject = some(chalk)
    c
  except:
    # exception was raised while processing chalk so bubble up
    # the errors to the system errors log so that report
    # is not missing any critical debugging logs while individual
    # chalk was being processed
    systemErrors &= chalk.err
    raise
  finally:
    collectionCtx.currentErrorObject = previous

proc isMarked*(chalk: ChalkObj): bool {.inline.} =
  return chalk.marked

proc newChalk*(name:         string            = "",
               chalkId:      string            = "",
               pid:          Option[Pid]       = none(Pid),
               fsRef:        string            = "",
               imageId:      string            = "",
               containerId:  string            = "",
               marked:       bool              = false,
               resourceType: set[ResourceType] = {ResourceFile},
               extract:      ChalkDict         = ChalkDict(nil),
               cache:        RootRef           = RootRef(nil),
               codec:        Plugin            = Plugin(nil),
               platform                        = DockerPlatform(nil),
               noAttestation                   = false,
               ): ChalkObj =

  result = ChalkObj(name:          name,
                    pid:           pid,
                    fsRef:         fsRef,
                    imageId:       imageId,
                    repos:         newOrderedTable[string, DockerImageRepo](),
                    containerId:   containerId,
                    collectedData: ChalkDict(),
                    objectsData:   ObjectsDict(),
                    opFailed:      false,
                    resourceType:  resourceType,
                    extract:       extract,
                    cache:         cache,
                    myCodec:       codec,
                    failedKeys:    ChalkDict(),
                    platform:      platform,
                    noAttestation: noAttestation,
                   )

  if chalkId != "":
    result.collectedData["CHALK_ID"] = pack(chalkId)

  if extract != nil and len(extract) > 1:
    result.marked = true

template setIfNotEmptyBox*(o: ChalkDict, k: string, v: Box) =
  case v.kind
  of MkSeq, MkTable, MkStr:
    if len(v) > 0:
      o[k] = v
  else:
    o[k] = v

template setIfNotEmpty*[T](o: ChalkDict, k: string, v: T) =
  when T is Box:
    setIfNotEmptyBox(o, k, v)
  elif T is JsonNode:
    if v != nil:
      setIfNotEmptyBox(o, k, v.nimJsonToBox())
  elif T is Option:
    if v.isSome():
      setIfNotEmptyBox(o, k, pack(v.get()))
  else:
    setIfNotEmptyBox(o, k, pack(v))

template setFromEnvVar*(o: ChalkDict, k: string, default: string = "") =
  o.setIfNotEmpty(k, os.getEnv(k, default))

template isSubscribedKey*(key: string): bool =
  subscribedKeys.getOrDefault(key, false)

template setIfSubscribed*[T](o: ChalkDict, k: string, v: T) =
  if isSubscribedKey(k):
    # need to normalize additional types to box to match setIfNeeded behavior
    when T is JsonNode:
      o[k] = v.nimJsonToBox()
    elif T is Option:
      if v.isSome():
        i[k] = pack(v.get())
    else:
      o[k] = pack(v)

template setIfNeeded*[T](o: ChalkDict, k: string, v: T) =
  if isSubscribedKey(k):
    setIfNotEmpty[T](o, k, v)

template setIfNeeded*[T](o: ChalkObj, k: string, v: T) =
  setIfNeeded(o.collectedData, k, v)

template trySetIfNeeded*(o: ChalkDict, k: string, code: untyped) =
  try:
    o.setIfNeeded(k, code)
  except:
    trace("Could not set chalk key " & k & " due to: " & getCurrentExceptionMsg())

proc idFormat*(rawHash: string): string =
  let s = base32vEncode(rawHash)
  s[0 ..< 6] & "-" & s[6 ..< 10] & "-" & s[10 ..< 14] & "-" & s[14 ..< 20]

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

template withSuspendChalkCollectionFor*(plugins: seq[string], c: untyped) =
  trace("plugins temporarily suspended: " & $plugins)
  for p in plugins:
    suspendChalkCollectionFor(p)
  try:
    c
  finally:
    trace("plugins restored: " & $plugins)
    for p in plugins:
      restoreChalkCollectionFor(p)

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

proc copyCollectedDataFrom*(self: ChalkObj, other: ChalkObj): ChalkObj =
  # attestation keys are not transferrable between diff chalk objects
  # as obviously signatures will not match
  let ignore = @["CHALK_ID", "METADATA_ID", "HASH"] & attrGet[seq[string]]("plugin.attestation.pre_chalk_keys")
  for k, v in other.extract:
    if k notin self.collectedData and not k.startsWith("$") and k notin ignore:
      self.collectedData[k] = v
  return self

proc makeNewValuesAvailable*(chalk: ChalkObj) =
  if chalk.extract == nil:
    chalk.extract = ChalkDict()
  for item, value in chalk.collectedData:
    if item.startsWith("$"):
      chalk.extract[item] = value

proc isChalked*(chalk: ChalkObj): bool =
  return chalk.extract != nil
