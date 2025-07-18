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

# this const is not available in nim stdlib hence manual c import
var TIOCNOTTY {.importc, header: "sys/ioctl.h".}: cuint
var RLIMIT_AS {.importc, header: "sys/resource.h".}: cint

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

proc detachFromParent*() =
  discard setpgid(0, 0) # Detach from the process group.
  if isatty(0) != 0:
    # if stdin is TTY, detach from it in child process
    # otherwise child process will receive HUP signal
    # on exit which is not expected
    discard ioctl(0, TIOCNOTTY) # Detach TTY for stdin

proc setRlimit*(limit: int) =
  if limit > 0:
    trace("exec: setting rlimit to: " & $limit)
    var l = RLimit(
      rlim_cur: limit,
      rlim_max: limit,
    )
    discard setrlimit(RLIMIT_AS, l)
