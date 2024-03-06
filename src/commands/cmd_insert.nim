##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk insert` command.

import ".."/[config, collect, reporting, chalkjson, plugin_api]


proc runCmdInsert*(path: seq[string]) {.exportc,cdecl.} =
  setContextDirectories(path)
  initCollection()
  let virtual = chalkConfig.getVirtualChalk()

  for item in artifacts(path):
    trace(item.name & ": begin chalking")
    item.collectChalkTimeArtifactInfo()
    trace(item.name & ": chalk data collection finished.")
    if item.isMarked() and "$CHALK_CONFIG" in item.extract:
      info(item.name & ": Is a configured chalk exe; skipping insertion.")
      item.removeFromAllChalks()
      item.forceIgnore = true
      continue
    if item.opFailed:
      continue
    try:
      let toWrite = item.getChalkMarkAsStr()
      if virtual:
        publish("virtual", toWrite)
        info(item.name & ": virtual chalk created.")
      else:
        item.callHandleWrite(some(toWrite))
        if not item.opFailed:
          info(item.name & ": chalk mark successfully added")

    except:
      error(item.name & ": insertion failed: " & getCurrentExceptionMsg())
      dumpExOnDebug()
      item.opFailed = true

  doReporting()
