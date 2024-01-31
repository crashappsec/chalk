##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk dump` command.

import std/posix
import ".."/[config, selfextract]

const
  configKey = "$CHALK_CONFIG"
  paramKey  = "$CHALK_SAVED_COMPONENT_PARAMETERS"
  cacheKey  = "$CHALK_COMPONENT_CACHE"

template baseDump(code: untyped) {.dirty.} =
  var
    toDump: string
    chalk   = getSelfExtraction().getOrElse(nil)
    extract = if chalk != nil: chalk.extract else: nil

  code

  publish("confdump", toDump)
  quit(0)

proc dumpToFile*() =
  baseDump:
    toDump = if extract == nil or configKey notin extract:
               defaultConfig
             else:
               unpack[string](extract[configKey])

proc runCmdConfDump*() =
  let args = getArgs()

  if len(args) > 0 or isatty(1) == 0:
    dumpToFile()

  baseDump:
    var s: string
    if chalk != nil and extract != nil and configKey in extract:
      s = unpack[string](extract[configKey])
    else:
      s = defaultConfig

    toDump = $code(s)

proc runCmdConfDumpParams*() =
  baseDump:
    if chalk == nil or extract == nil or paramKey notin extract:
      toDump = "[]"
    else:
      toDump = boxToJson(extract[paramKey])

proc runCmdConfDumpCache*() =
  baseDump:
    var 
      r: Rope
      cells: seq[seq[Rope]]
    if chalk == nil or extract == nil or cacheKey notin extract:
      runCmdConfDump()

    let
      componentInfo = selfChalk.extract[cacheKey]
      unpackedInfo  = unpack[OrderedTableRef[string, string]](componentInfo)

    for url, contents in unpackedInfo:
      cells = @[@[pre(code(contents))]]
      r += cells.quickTable(noheaders = true, title = atom("URL: " & url))

    toDump = $r
