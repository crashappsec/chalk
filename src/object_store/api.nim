##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[tables, uri]
import ".."/[config, normalize]
import "."/[presign]

let objectStores = {
  presignObjectStore.name: presignObjectStore,
}.toTable()

var objectStoreConfigs: Table[string, ObjectStoreConfig]

proc getObjectStoreConfigByName(name: string): ObjectStoreConfig =
  if name in objectStoreConfigs:
    return objectStoreConfigs[name]

  let
    configSection  = "object_store_config." & name
    storeTypeSection = configSection & ".object_store"

  if not sectionExists(configSection):
    raise newException(ValueError, configSection & " is referenced but its missing in the config")

  let storeType = attrGet[string](storeTypeSection)
  if storeType == "":
    raise newException(ValueError, configSection & " is referenced but its missing in the config")

  let store = objectStores[storeType]
  result = store.init(store, name)
  objectStoreConfigs[name] = result

proc newObjectStoreRef*(self:          ObjectStoreConfig,
                        k:             string,
                        data:          string,
                        canonicalData: Box,
                        ): ObjectStoreRef =
  return ObjectStoreRef(
    config: self,
    key:    k,
    id:     canonicalData.binEncodeItem().sha256Hex(),
    digest: data.sha256Hex(),
  )

proc `$`(self: ObjectStoreRef): string =
  var uri = self.config.store.uri(self.config, self)
  if self.query != "":
    var queries = newSeq[(string, string)]()
    for k, v in decodeQuery(uri.query):
      queries.add((k, v))
    for k, v in decodeQuery(self.query):
      queries.add((k, v))
    uri.query = encodeQuery(queries)
  result = $uri

proc canonicalizeKey(key: string, data: Box): Box =
  let callbackOpt = attrGetOpt[CallbackObj]("keyspec." & key & ".canonicalize")
  if callbackOpt.isNone():
    trace("object store: no canonicalize() for " & key)
    return data
  let callback = callbackOpt.get()
  trace("object store: canonicalizing " & key & " with " & $callback)
  try:
    let canonicalized = runCallback(callback, @[data])
    if canonicalized.isNone():
      error("object store: missing implementation to canonicalize " & key & " for " & $callback)
      return data
    return canonicalized.get()
  except:
    error("object store: failed to canonicalize " & key & " due to:" & getCurrentExceptionMsg())
    dumpExOnDebug()
    return data

proc objectifyKey(dict:            ChalkDict,
                  k:               string,
                  v:               Box,
                  content:         string,
                  objectsData:     ObjectsDict,
                  storeConfigName: string) =
  let objectRefs = objectsData.mgetOrPut(storeConfigName, newOrderedTable[string, ObjectStoreRef]())
  # key was already objectified before. use existing ref
  if k in objectRefs:
    dict[objectStorePrefix & k] = pack($(objectRefs[k]))
    return
  let
    storeConfig = getObjectStoreConfigByName(storeConfigName)
    canonical   = canonicalizeKey(k, v)
    lookupRef   = newObjectStoreRef(storeConfig, k, content, canonical)
  var storeRef: ObjectStoreRef
  try:
    trace("object store: looking up key in object store: " & $lookupRef)
    storeRef = storeConfig.store.objectExists(storeConfig, lookupRef)
    if storeRef == nil:
      try:
        trace("object store: creating key in object store: " & $lookupRef)
        storeRef = storeConfig.store.createObject(storeConfig, lookupRef, content)
      except:
        let e = getCurrentExceptionMsg()
        # it is possible multiple chalks might be trying to upload the same object/hash
        # to the object store at the same time in which case only one should succeed
        # and so just in case attempt to fetch existing object again
        # p.s. this is more likely for externally created metadata
        # where there could be many builds referencing the same metadata
        # such as _IMAGE_SBOM for a base image like alpine
        trace("object store: attempting to refetch object to handle possible creation race conditions")
        storeRef = storeConfig.store.objectExists(storeConfig, lookupRef)
        if storeRef == nil:
          error("object store: could not upload object " & $lookupRef & " due to: " & e)
          dumpExOnDebug()
  except:
    error("object store: could not lookup existing object " & $lookupRef & " due to: " & getCurrentExceptionMsg())
    dumpExOnDebug()
  if storeRef != nil:
    objectRefs[k] = storeRef
    dict[objectStorePrefix & k] = pack($storeRef)
  else:
    error("object store: could not either lookup existing or upload object for " & k)
    dict[k] = v

proc objectifyByTemplate*(collectedData: ChalkDict,
                          objectsData: ObjectsDict,
                          temp: string,
                          ): ChalkDict =
  let
    defaultEnabled         = attrGetOpt[bool](temp & ".default_object_store.enabled").get(false)
    defaultStoreConfigName = attrGetOpt[string](temp & ".default_object_store.object_store").get("")
    defaultThreshold       = attrGetOpt[Con4mSize](temp & ".default_object_store.threshold").get(0)
    useDefault             = defaultEnabled and defaultStoreConfigName != "" and defaultThreshold > 0
  result = ChalkDict()
  for k, v in collectedData:
    let
      storeConfigName = attrGetOpt[string](temp & ".key." & k & ".object_store").get("")
      enabled         = attrGetOpt[bool]("object_store_config." & storeConfigName & ".enabled").get(false)
      useStore        = enabled and storeConfigName != ""
      content         = v.boxToJson()
    if useStore:
      trace("object_store: using per-key " & k & " object store " & storeConfigName)
      objectifyKey(result, k, v, content, objectsData, storeConfigName)
    elif useDefault and Con4mSize(len(content)) > defaultThreshold:
      trace("object_store: using default object store " & defaultStoreConfigName)
      objectifyKey(result, k, v, content, objectsData, defaultStoreConfigName)
    else:
      result[k] = v
