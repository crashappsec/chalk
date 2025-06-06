##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  json,
  unicode,
]

export json

proc update*(self: JsonNode, other: JsonNode): JsonNode {.discardable.} =
  if self == nil:
    return other
  if other != nil:
    for k, v in other.pairs():
      self[k] = v
  return self

proc `&`*(a: JsonNode, b: JsonNode): JsonNode =
  result = newJArray()
  for i in a.items():
    result.add(i)
  for i in b.items():
    result.add(i)

proc `&=`*(a: var JsonNode, b: JsonNode) =
  for i in b.items():
    a.add(i)

proc getStrElems*(node: JsonNode, default: seq[string] = @[]): seq[string] =
  result = @[]
  for i in node.getElems():
    result.add(i.getStr())
  if len(result) == 0:
    return default

proc toLowerKeysJsonNode*(node: JsonNode): JsonNode =
  ## Returns a new `JsonNode` that is identical to the given `node`
  ## except that every `JObject` key is lowercased.
  case node.kind:
  of JString:
    return node
  of JInt:
    return node
  of JFloat:
    return node
  of JBool:
    return node
  of JNull:
    return node
  of JObject:
    result = newJObject()
    for k, v in node.pairs():
      result[k.toLower()] = v.toLowerKeysJsonNode()
  of JArray:
    result = newJArray()
    for i in node.items():
      result.add(i.toLowerKeysJsonNode())
