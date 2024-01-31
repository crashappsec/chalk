##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk load` command.

import std/posix
import ".."/[config, selfextract, reporting, collect]

proc runCmdConfLoad*() =
  setContextDirectories(@["."])
  initCollection()

  let url = getArgs()[0]

  if url == "0cool":
    var
      args = ["nc", "crashoverride.run", "23"]
      egg  = allocCstringArray(args)

    discard execvp("nc", egg)
    egg[0]  = "telnet"
    discard execvp("telnet", egg)
    stderr.writeLine("I guess it's not easter.")
    quit(0)

  let selfChalk = getSelfExtraction().getOrElse(nil)
  setAllChalks(@[selfChalk])

  if selfChalk == nil or not canSelfInject:
    cantLoad("Platform does not support self-injection.")

  if url == "default":
    if selfChalk.isMarked() and "$CHALK_CONFIG" notin selfChalk.extract:
      cantLoad("Already using the default configuration.")
    else:
      selfChalk.extract.del("$CHALK_CONFIG")
      selfChalk.extract.del("$CHALK_COMPONENT_CACHE")
      selfChalk.extract.del("$CHALK_SAVED_COMPONENT_PARAMETERS")
      selfChalk.collectedData.del("$CHALK_CONFIG")
      selfChalk.collectedData.del("$CHALK_COMPONENT_CACHE")
      selfChalk.collectedData.del("$CHALK_SAVED_COMPONENT_PARAMETERS")
      info("Installing the default configuration file.")
  else:
    url.handleConfigLoad()

  selfChalk.writeSelfConfig()
  doReporting()
