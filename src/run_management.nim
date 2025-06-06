##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common items related to managing the chalk run, including key
## setting, status stuff, and the core scan state ("collection
## contexts"), that the subscan module pushes and pops.

import std/[
  enumerate,
  os,
  posix,
]
import pkg/[
  con4m,
]
import "."/[
  types,
  utils/json,
  utils/strings,
  utils/times,
]

var ctxStack = @[CollectionCtx()]

# This is for when we're doing a `conf load`.  We force silence, turning off
# all logging of merit.
proc startTestRun*() =
  doingTestRun = true
proc endTestRun*()   =
  doingTestRun = false

template withOnlyCodecs*(codecs: seq[Plugin], c: untyped) =
  if len(codecs) > 0:
    var names = newSeq[string]()
    for i in codecs:
      names.add(i.name)
    trace("Restricting scanning codecs to only " & $names)
    let saved = onlyCodecs
    onlyCodecs = codecs
    try:
      c
    finally:
      onlyCodecs = saved
  else:
    c

template getOnlyCodecs*(): seq[Plugin] =
  onlyCodecs

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

proc addIfMissing(to: var seq[ChalkObj], o: ChalkObj) =
  let check = collectionCtx.allChalks & collectionCtx.allArtifacts
  if o in check:
    return
  if "CHALK_ID" in o.collectedData:
    let id = o.collectedData["CHALK_ID"]
    for i in check:
      if "CHALK_ID" in i.collectedData:
        let otherId = i.collectedData["CHALK_ID"]
        if id == otherId:
          return
  to.add(o)

proc getCurrentCollectionCtx*(): CollectionCtx =
  collectionCtx
proc getErrorObject*(): Option[ChalkObj] =
  collectionCtx.currentErrorObject
proc getAllChalks*(): seq[ChalkObj] =
  collectionCtx.allChalks
proc getAllChalks*(cc: CollectionCtx): seq[ChalkObj] =
  cc.allChalks
proc addToAllChalks*(o: ChalkObj) =
  collectionCtx.allChalks.addIfMissing(o)
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
  collectionCtx.allArtifacts.addIfMissing(o)
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

proc newChalk*(name:          string            = "",
               chalkId:       string            = "",
               pid:           Option[Pid]       = none(Pid),
               fsRef:         string            = "",
               imageId:       string            = "",
               containerId:   string            = "",
               marked:        bool              = false,
               resourceType:  set[ResourceType] = {ResourceFile},
               extract:       ChalkDict         = ChalkDict(nil),
               collectedData: ChalkDict         = ChalkDict(),
               cache:         RootRef           = RootRef(nil),
               codec:         Plugin            = Plugin(nil),
               platform                         = DockerPlatform(nil),
               noAttestation                    = false,
               startOffset                      = 0,
               ): ChalkObj =

  result = ChalkObj(name:          name,
                    pid:           pid,
                    fsRef:         fsRef,
                    imageId:       imageId,
                    repos:         newOrderedTable[string, DockerImageRepo](),
                    containerId:   containerId,
                    objectsData:   ObjectsDict(),
                    opFailed:      false,
                    resourceType:  resourceType,
                    collectedData: collectedData,
                    extract:       extract,
                    cache:         cache,
                    myCodec:       codec,
                    failedKeys:    ChalkDict(),
                    platform:      platform,
                    noAttestation: noAttestation,
                    startOffset:   startOffset,
                   )

  if chalkId != "":
    result.collectedData["CHALK_ID"] = pack(chalkId)

  if extract != nil and len(extract) > 1:
    result.marked = true

template setIfNotEmptyBox*(o: ChalkDict, k: string, v: Box) =
  let value = v
  case value.kind
  of MkSeq, MkTable, MkStr:
    if len(value) > 0:
      o[k] = value
  else:
    o[k] = value

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
