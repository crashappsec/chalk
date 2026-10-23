##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  posix,
]
import pkg/nimutils as upstream_nimutils

proc getMyAppPath*(): string =
  when hostOS == "linux":
    # "self" remains correct when /proc comes from an enclosing PID namespace.
    var buffer: array[4096, char]
    let count = readlink(
      cstring("/proc/self/exe"),
      cast[cstring](addr buffer[0]),
      len(buffer) - 1,
    )
    if count < 0:
      raiseOSError(osLastError(), "cannot resolve /proc/self/exe")
    if count == 0 or count >= len(buffer) - 1:
      raise newException(OSError, "invalid /proc/self/exe target")
    buffer[count] = '\0'
    return $cast[cstring](addr buffer[0])
  else:
    result = upstream_nimutils.getMyAppPath()
    if result == "":
      raise newException(OSError, "cannot resolve executable path")
