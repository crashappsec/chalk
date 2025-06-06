##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  posix,
]
import pkg/[
  nimutils/logging,
]
import "."/[
  strings,
]

var exitCode = 0

proc quitChalk*(errCode = exitCode) {.noreturn.} =
  quit(errCode)

proc getExitCode*(): int =
  return exitCode

proc setExitCode*(code: int): int {.discardable.} =
  exitCode = code
  return code

proc handleExec*(prioritizedExes: seq[string], args: seq[string]) {.noreturn.} =
  for path in prioritizedExes:
    let cargs = allocCStringArray(@[path] & args)
    trace("execv: " & path & " " & args.join(" "))
    discard execv(cstring(path), cargs)
    # Either execv doesn't return, or something went wrong. No need to check the
    # error code.
    error("Chalk: when execing '" & path & "': " & $(strerror(errno)))

  error("Chalk: exec could not find a working executable to run.")
  quitChalk(1)
