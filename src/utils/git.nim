##
## Copyright (c) 2024-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  types,
]
import "."/[
  exe,
]

var gitExeLocation = ""

proc setGitExeLocation*() =
  once:
    gitExeLocation = exe.findExePath("git").get("")
    if gitExeLocation == "":
      error("No git command found in PATH")
      raise newException(ValueError, "No git")

proc getGitExeLocation*(): string =
  once:
    try:
      setGitExeLocation()
    except:
      discard
  return gitExeLocation
