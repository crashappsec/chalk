##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## docker-specific json utils for collecting docker inspected metadata

import std/[json]
import ".."/[config, chalkjson, util]
import "."/[ids]

proc parseAndDigestJson*(data: string): DigestedJson =
  return DigestedJson(
    json:   parseJson(data),
    digest: "sha256:" & sha256(data).hex(),
    size:   len(data),
  )

proc parseAndDigestJson*(data: string, digest: string): DigestedJson =
  return DigestedJson(
    json:   parseJson(data),
    digest: digest,
    size:   len(data),
  )

proc newDockerDigestedJson*(data:      string,
                            digest:    string,
                            mediaType: string,
                            kind:      DockerManifestType,
                            ): DockerDigestedJson =
  return DockerDigestedJson(
    json:      parseJson(data),
    digest:    "sha256:" & extractDockerHash(digest),
    size:      len(data),
    mediaType: mediaType,
    kind:      kind,
  )

type
  JsonTransformer*        = proc (node: JsonNode): JsonNode
  JsonToChalkKeysMapping* = OrderedTable[string, (string, JsonTransformer)]

proc identityProc(node: JsonNode): JsonNode =
  return node

let identity* = JsonTransformer(identityProc)

proc getByPathOpt(top: JsonNode, key: string): Option[JsonNode] =
  # if the key in json has dots hence split below will not find the key
  if key in top:
    return some(top[key])
  var cur = top
  for item in key.split('.'):
    if cur.kind != JObject:
      return none(JsonNode)
    if item notin cur:
      return none(JsonNode)
    cur = cur[item]
  return some(cur)

proc mapFromJson(self:         ChalkDict,
                 node:         JsonNode,
                 jsonKey:      string,
                 chalkKey:     string,
                 transformer:  JsonTransformer,
                 reportEmpty = false) =
  if not chalkKey.isSubscribedKey():
    return

   # no value exists in json
  if node == nil or node.kind == JNull:
    return

  # Handle any transformations we know we need.
  var value = transformer(node)

  if not reportEmpty:
    case value.kind
    of JString:
      if value.getStr() == "": return
    of JArray:
      if len(value) == 0: return
    of JObject:
      if len(value) == 0: return
    else:
      discard

  let boxedValue = value.nimJsonToBox()
  let t = attrGet[Con4mType]("keyspec." & chalkKey & ".type")
  if not boxedValue.checkAutoType(t):
    warn("docker: JSON key " & jsonKey &
         " associated with chalk key '" & chalkKey &
         "' is not of the expected type. Using it anyway.")

  self[chalkKey] = boxedValue

proc mapFromJson*(self: ChalkDict,
                  node: JsonNode,
                  map:  JsonToChalkKeysMapping) =
  let
    reportEmpty = attrGet[bool]("docker.report_empty_fields")
    lowerJson   = node.toLowerKeysJsonNode()
  for jsonKey, (chalkKey, transformer) in map:
    try:
      let subJsonOpt = lowerJson.getByPathOpt(jsonKey.toLower())
      if subJsonOpt.isNone():
        continue
      self.mapFromJson(subJsonOpt.get(), jsonKey, chalkKey, transformer, reportEmpty)
    except:
      warn("docker: skipping failure mapping docker metadata key " & jsonKey &
           " to chalk key " & chalkKey & " due to: " & getCurrentExceptionMsg())
