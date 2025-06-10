##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  times,
  monotimes,
]
import ".."/[
  con4mwrap,
]

export times
export monotimes

var
  startTime*     = getTime().utc # gives absolute wall time
  monoStartTime* = getMonoTime() # used for computing diffs

template withDuration*(c: untyped) =
  let start = getMonoTime()
  c
  let
    stop                = getMonoTime()
    diff                = stop - start
    duration {.inject.} = diff

proc toUnixInMs*(t: DateTime): int64 =
  let epoch = fromUnix(0).utc
  return (t - epoch).inMilliseconds()

proc forReport*(t: DateTime): DateTime =
  ## convert datetime to timezone for reporting chalk keys
  # eventually we might add a config to specify in which TZ to report in
  # however for now normalize to local timezone for reading report output
  return t.local

proc reportTotalTime*() =
  let monoEndTime = getMonoTime()
  if attrGet[bool]("report_total_time"):
    echo("Total run time: " & $(monoEndTime - monoStartTime))
