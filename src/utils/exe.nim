##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This is for any common code for system stuff, such as executing
## code.

import std/[
  options,
  os,
  posix,
]
import pkg/[
  nimutils,
  nimutils/logging,
]
import ".."/[
  plugin_api,
  run_management,
  subscan,
  types,
]

proc findExePath*(cmdName:    string,
                  extraPaths: seq[string] = @[],
                  configPath: Option[string] = none(string),
                  usePath         = true,
                  ignoreChalkExes = false): Option[string] =
  var paths = extraPaths
  if configPath.isSome():
    # prepend on purpose so that config path
    # takes precedence over rest of dirs in PATH
    paths = @[configPath.get()] & paths

  trace("Searching PATH for " & cmdName)
  var foundExes = findAllExePaths(cmdName, paths, usePath)

  if ignoreChalkExes:
    var newExes: seq[string]

    withOnlyCodecs(getNativeCodecs()):
      for location in foundExes:
        let
          subscan   = runChalkSubScan(location, "extract")
          allChalks = subscan.getAllChalks()
          isChalk   = (
            len(allChalks) != 0 and
            allChalks[0].extract != nil and
           "$CHALK_IMPLEMENTATION_NAME" in allChalks[0].extract
          )
        if not isChalk:
          newExes.add(location)
          break

    foundExes = newExes

  if foundExes.len() == 0:
    trace("Could not find '" & cmdName & "' in PATH.")
    return none(string)

  trace("Found '" & cmdName & "' in PATH: " & foundExes[0])
  return some(foundExes[0])

proc makeExecutable*(path: string) =
  let
    existing = path.getFilePermissions()
    wanted   = existing + {fpUserExec, fpGroupExec, fpOthersExec}
  if existing != wanted:
    path.setFilePermissions(wanted)
