##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[config, util]

proc extractDockerHash*(value: string): string =
  const hashHeader = "sha256:"
  # this function is also used to process container ids
  # which can start with / hence the strip
  return value.removePrefix(hashHeader).strip(chars = {'/'})

proc extractDockerHash*(value: Box): Box =
  return pack(extractDockerHash(unpack[string](value)))

proc extractDockerHashList*(value: seq[string]): seq[string] =
  for item in value:
    result.add(item.extractDockerHash())

proc extractDockerHashMap*(value: seq[string]): OrderedTable[string, string] =
  result = initOrderedTable[string, string]()
  for item in value:
    if '@' notin item:
      raise newException(
        ValueError,
        "Invalid docker repo name. Expecting <repo>@sha256:<digest> but got: " & item
      )
    let (repo, hash) = item.splitBy("@")
    result[repo] = hash.extractDockerHash()
