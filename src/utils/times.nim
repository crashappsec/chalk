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
  processStartTime* = getTime().utc # set once at startup, never reset
  processMonoTime*  = getMonoTime() # set once at startup, never reset
  opTime*           = processStartTime # current operation wall time, reset each heartbeat
  opMonoTime*       = processMonoTime  # current operation mono time, reset each heartbeat

proc toMs*(t: MonoTime): int64 =
  t.ticks div 1_000_000

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
    echo("Total run time: " & $(monoEndTime - processMonoTime))
