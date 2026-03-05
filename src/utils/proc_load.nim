##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  strscans,
]
import pkg/[
  nimutils,
]
import "."/[
  json,
  strings,
]

proc getLoadInfo*(): JsonNode =
  let info = tryToLoadFile("/proc/loadavg").strip()
  let (isMatch, min1, min5, min15, running, total, last) = info.scanTuple("$f $f $f $i/$i $i")
  if not isMatch:
    return newJObject()
  result = %*({
    "load": {
      "1":  min1,
      "5":  min5,
      "15": min15,
    },
    "runnable_procs": running,
    "total_procs":    total,
    "lastpid":        last,
  })
