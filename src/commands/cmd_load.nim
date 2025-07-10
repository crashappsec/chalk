##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk load` command.

import std/[
  posix,
]
import ".."/[
  collect,
  plugin_api,
  reporting,
  run_management,
  selfextract,
  types,
]

proc runCmdConfLoad*() =
  setContextDirectories(@["."])
  initCollection()

  let url = getArgs()[0]

  if url == "0cool":
    var
      args = ["nc", "crashoverride.run", "23"]
      egg  = allocCStringArray(args)

    discard execvp("nc", egg)
    egg[0]  = "telnet"
    discard execvp("telnet", egg)
    stderr.writeLine("I guess it's not easter.")
    quit(0)

  let selfChalk = getSelfExtraction().getOrElse(nil)
  setAllChalks(@[selfChalk])

  if selfChalk == nil or not canSelfInject:
    cantLoad("Platform does not support self-injection.")

  let updated =
    if url == "default":
      if selfChalk.isMarked() and "$CHALK_CONFIG" notin selfChalk.extract:
        false
      else:
        selfChalk.extract.del("$CHALK_CONFIG")
        selfChalk.extract.del("$CHALK_COMPONENT_CACHE")
        selfChalk.extract.del("$CHALK_SAVED_COMPONENT_PARAMETERS")
        selfChalk.collectedData.del("$CHALK_CONFIG")
        selfChalk.collectedData.del("$CHALK_COMPONENT_CACHE")
        selfChalk.collectedData.del("$CHALK_SAVED_COMPONENT_PARAMETERS")
        info("Installing the default configuration file.")
        true
    else:
      for plugin in getAllPlugins():
        if not plugin.isSystem:
          suspendChalkCollectionFor(plugin.name)
      url.handleConfigLoad()

  if updated:
    selfChalk.writeSelfConfig()
  else:
    info("Chalk is already using same configuration. Nothing to load")

  doReporting()
