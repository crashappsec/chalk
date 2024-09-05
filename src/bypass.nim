##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[os, strutils]
import pkg/nimutils/[file]
import "."/[util]

proc bypassChalk*() =
  ## Bypasses any chalk execution if possible and directly execs the underlying command.
  ## Note this function explicitly writes to stderr for "logging" to avoid invoking
  ## any of the con4m machinery.
  if getEnv("CHALK_BYPASS").toLower() notin @["1", "true", "on"]:
    return

  let
    (path, exe) = getAppFilename().splitPath()
    # setup.sh for example stores chalkless variants of binaries
    # in chalkless folder
    # we need to account for it as otherwise original binary
    # might not be on PATH overwise
    # and as we don't load the chalk config here as a precaution
    # and so we must mimic disk structure directly
    chalklessDir = path.parentDir().joinPath("chalkless")

  case exe
  of "docker":
    let chalkless = file.findExePath(exe, extraPaths = @[chalklessDir])
    if chalkless == "":
      stderr.writeLine("Could not find " & exe & " to exec while bypassing chalk")
      quitChalk(1)
    handleExec(@[chalkless], commandLineParams(), log = false)
  else:
    return
