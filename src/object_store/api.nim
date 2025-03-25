##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[tables, uri]
import ".."/[config]
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

proc newObjectStoreRef*(self: ObjectStoreConfig, k: string, data: string): ObjectStoreRef =
  return ObjectStoreRef(
    config: self,
    key:    k,
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

proc objectifyByTemplate*(collectedData: ChalkDict,
                          objectsData: ObjectsDict,
                          temp: string,
                          ): ChalkDict =
  result = ChalkDict()
  for k, v in collectedData:
    let
      path            = temp & ".key." & k & ".object_store"
      storeConfigName = attrGetOpt[string](path).get("")
    # there is no object store for this key. use original value
    if storeConfigName == "":
      result[k] = v
      continue
    # object store is explicitly disabled. use original value
    let enabled = attrGetOpt[bool]("object_store_config." & storeConfigName & ".enabled").get(false)
    if not enabled:
      result[k] = v
      continue
    let objectRefs = objectsData.mgetOrPut(storeConfigName, newOrderedTable[string, ObjectStoreRef]())
    # key was already objectified before. use existing ref
    if k in objectRefs:
      result[objectStorePrefix & k] = pack($(objectRefs[k]))
      continue
    let
      storeConfig = getObjectStoreConfigByName(storeConfigName)
      data        = $v # TODO this is WRONG
      lookupRef   = newObjectStoreRef(storeConfig, k, data)
    var storeRef: ObjectStoreRef
    try:
      trace("object store: looking up key in object store: " & $lookupRef)
      storeRef = storeConfig.store.objectExists(storeConfig, lookupRef)
      if storeRef == nil:
        try:
          trace("object store: creating key in object store: " & $lookupRef)
          storeRef = storeConfig.store.createObject(storeConfig, lookupRef, data)
        except:
          error("object store: could not upload object " & $lookupRef & " due to: " & getCurrentExceptionMsg())
          dumpExOnDebug()
    except:
      error("object store: could not lookup existing object " & $lookupRef & " due to: " & getCurrentExceptionMsg())
      dumpExOnDebug()
    if storeRef != nil:
      objectRefs[k] = storeRef
      result[objectStorePrefix & k] = pack($storeRef)
    else:
      error("object store: could not either lookup existing or upload object for " & k)
      result[k] = v
