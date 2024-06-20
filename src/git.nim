##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import "."/[config, util]

proc setGitExeLocation*() =
  once:
    gitExeLocation = util.findExePath("git").get("")
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
