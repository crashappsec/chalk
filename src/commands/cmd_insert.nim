##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk insert` command.

import ".."/[config, collect, reporting, chalkjson, plugin_api, chalk_common, selfextract]
import "../plugins/codecZip"


proc runCmdInsert*(path: seq[string]) {.exportc,cdecl.} =
  setContextDirectories(path)
  initCollection()
  let virtual = attrGet[bool]("virtual_chalk")
  let injectBinary = attrGet[bool]("inject_binary")

  for item in artifacts(path):
    trace(item.name & ": begin chalking")

    # If binary injection is enabled, handle zip archives first
    if injectBinary:
      var isZip = false
      if item.myCodec != nil and item.myCodec.name == "zip":
        isZip = true

      if isZip:
        info(item.name & ": inserting binary into zip archive")

        # Insert binary before collecting chalk info
        if not insertChalkBinaryIntoZip(item):
          item.opFailed = true
          continue
      else:
        info(item.name & ": artifact is not a zip archive")

    # Now collect chalk info after possibly modifying the file
    item.collectChalkTimeArtifactInfo()
    trace(item.name & ": chalk data collection finished.")

    if item.isMarked() and configKey in item.extract:
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
