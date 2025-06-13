##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Implements recursive scanning, for instance, used to process
## contents of zip files.

import "."/[
  config,
  run_management,
  types,
]

# For the moment, this seems to be breaking our external dependency?!!!
proc runCmdInsert*(path: seq[string]) {.importc.}
proc runCmdExtract*(path: seq[string]) {.importc.}
proc runCmdDelete*(path: seq[string]) {.importc.}

proc runChalkSubScan*(location: seq[string],
                      cmd:      string,
                      suspendHost = true): CollectionCtx =
  let
    oldRecursive = attrGet[bool]("recursive")
    oldCmd       = getCommandName()
    oldArgs      = getArgs()
    logLevel     = getLogLevel()

  setCommandName(cmd)
  setArgs(location)
  trace("Running subscan. Command name is temporarily: " & cmd)
  trace("Subscan location: " & $(location))

  var savedLogLevel: Option[LogLevel]

  if logLevel > llError and not attrGet[bool]("chalk_debug"):
    trace("*** Setting log-level = \"error\" for scan.  Use --debug to turn on")
    savedLogLevel = some(logLevel)
    setLogLevel(llError)

  let runtime = getChalkRuntime()
  result = pushCollectionCtx()
  try:
    if suspendHost:
      suspendHostCollection()
    runtime.con4mAttrSet("recursive", pack(true))
    case cmd
    # if someone is doing 'docker' recursively, we look
    # at the file system instead of a docker file.
    of "insert", "build": runCmdInsert(location)
    of "extract": runCmdExtract(location)
    of "delete":  runCmdDelete(location)
    else: discard
  finally:
    popCollectionCtx()
    if suspendHost:
      restoreHostCollection()

    if savedLogLevel.isSome():
      setLogLevel(savedLogLevel.get())

    setCommandName(oldCmd)
    setArgs(oldArgs)
    trace("subscan: found " & $len(result.allChalks) & " artifacts")
    trace("Subscan done. Restored command name to: " & oldCmd)
    runtime.con4mAttrSet("recursive", pack(oldRecursive))

template runChalkSubScan*(location: string,
                          cmd:      string,
                          suspendHost = true): CollectionCtx =
    runChalkSubScan(@[location], cmd, suspendHost)
