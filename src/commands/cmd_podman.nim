##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  commands/cmd_help,
  types,
  utils/exec,
]
import "../podman"/[
  build,
]

proc runCmdPodman*(args: seq[string]) {.noreturn.} =
  if getChalkScope().contents["log_level"].get(Attribute).override.isNone():
    setLogLevel(attrGet[string]("podman_log_level"))
  let exitCode = runPodman(args)
  try:
    showConfigValues()
  except:
    discard
  quitChalkWithStatus(exitCode)
