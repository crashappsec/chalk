##
## Copyright (c) 2024-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import pkg/[
  parsetoml,
]
import "."/[
  json,
  strings,
]

export parsetoml

proc fromTomlJson*(x: JsonNode): JsonNode =
  case x.kind
  of JObject:
    if "type" in x and "value" in x:
      case x{"type"}.getStr()
      of "bool":
        return %(x{"value"}.getStr().toLower() == "true")
      else:
        return x{"value"}.fromTomlJson()
    else:
      result = newJObject()
      for k, v in x.pairs():
        result[k] = v.fromTomlJson()
  of JArray:
    result = newJArray()
    for i in x:
      result.add(i.fromTomlJson())
  else:
    return x
