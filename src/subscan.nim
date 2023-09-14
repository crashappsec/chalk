##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Implements recursive scanning, for instance, used to process
## contents of zip files.

import config

# For the moment, this seems to be breaking our external dependency?!!!
proc runCmdInsert*(path: seq[string]) {.importc.}
proc runCmdExtract*(path: seq[string]) {.importc.}
proc runCmdDelete*(path: seq[string]) {.importc.}

proc runChalkSubScan*(location: seq[string],
                      cmd:      string,
                      suspendHost = true): CollectionCtx =
  let
    oldRecursive = chalkConfig.recursive
    oldCmd       = getCommandName()
    oldArgs      = getArgs()
    logLevel     = getLogLevel()

  setCommandName(cmd)
  setArgs(location)
  trace("Running subscan. Command name is temporarily: " & cmd)
  trace("Subscan location: " & $(location))

  var savedLogLevel: Option[LogLevel]

  if logLevel > llError and not chalkConfig.chalkDebug:
    trace("*** Setting log-level = \"error\" for scan.  Use --debug to turn on")
    savedLogLevel = some(logLevel)
    setLogLevel(llError)

  try:
    if suspendHost:
      suspendHostCollection()
    chalkConfig.recursive = true
    result                = pushCollectionCtx()
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
    trace("Subscan done. Restored command name to: " & oldCmd)
    chalkConfig.recursive = oldRecursive

template runChalkSubScan*(location: string,
                          cmd:      string,
                          suspendHost = true): CollectionCtx =
    runChalkSubScan(@[location], cmd, suspendHost)
