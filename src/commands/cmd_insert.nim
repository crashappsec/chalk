##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk insert` command.

import ".."/[
  chalkjson,
  collect,
  plugin_api,
  reporting,
  run_management,
  selfextract,
  types,
]


proc runCmdInsert*(path: seq[string]) {.exportc,cdecl.} =
  setContextDirectories(path)
  initCollection()
  let virtual = attrGet[bool]("virtual_chalk")
  let lambda = attrGet[bool]("lambda_mode")

  for item in artifacts(path):
    trace(item.name & ": begin chalking")
    item.collectChalkTimeArtifactInfo()
    trace(item.name & ": chalk data collection finished.")

    # Check if lambda flag is present and handle zip archives
    if lambda:
      var isZip = false
      if item.collectedData != nil and "ARTIFACT_TYPE" in item.collectedData:
        try:
          isZip = item.collectedData["ARTIFACT_TYPE"] == artTypeZip
        except:
          isZip = false

      if isZip:
        info(item.name & ": inserting binary into zip")

        # insert the chalk binary itself into the zip file
        try:
          # get the currently executing chalk binary path
          let myAppPath = getMyAppPath()

          if myAppPath != "" and item.myCodec != nil and item.myCodec.name == "zip" and item.cache != nil:
            # we need to safely access the cache as ZipCache
            let chalkBinaryContent = tryToLoadFile(myAppPath)

            var zipCache: ZipCache
            try:
              zipCache = cast[ZipCache](item.cache)
              if zipCache == nil or zipCache.tmpDir == "":
                raise newException(ValueError, "Invalid ZipCache")

              # Get the path to add the binary
              let
                extractDir = joinPath(zipCache.tmpDir, "contents")
                chalkTargetPath = joinPath(extractDir, "chalk")

              # Make sure the contents directory exists
              if dirExists(extractDir):
                # Write the chalk binary to the zip contents directory
                if tryToWriteFile(chalkTargetPath, chalkBinaryContent):
                  # TODO: why isn't this working?
                  # ensure it is executable
                  chalkTargetPath.makeExecutable()
                  info(item.name & ": added chalk binary to zip")
                else:
                  error(item.name & ": failed to add chalk binary to zip")
                  item.opFailed = true
              else:
                error(item.name & ": contents directory does not exist")
                item.opFailed = true
            except:
              error(item.name & ": failed to access zip cache: " & getCurrentExceptionMsg())
              item.opFailed = true
          else:
            error(item.name & ": not a zip archive or missing required data")
            item.opFailed = true
        except:
          error(item.name & ": failed to insert chalk binary: " & getCurrentExceptionMsg())
          dumpExOnDebug()
          item.opFailed = true
      else:
        info(item.name & ": artifact is not a zip archive")

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
