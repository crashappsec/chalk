##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk dump` command.

import ../config, ../selfextract, unicode

const
  configKey = "$CHALK_CONFIG"
  paramKey  = "$CHALK_SAVED_COMPONENT_PARAMETERS"
  cacheKey  = "$CHALK_COMPONENT_CACHE"

template baseDump(code: untyped) {.dirty.} =
  var
    toDump: Rope
    chalk   = getSelfExtraction().getOrElse(nil)
    extract = if chalk != nil: chalk.extract else: nil

  code

  print(toDump)
  echo("")
  quit(0)

proc runCmdConfDump*() =
  baseDump:
    var s: string
    if chalk != nil and extract != nil and configKey in extract:
      s = unpack[string](extract[configKey])
    else:
      s = defaultConfig

    toDump = Rope(kind: RopeTaggedContainer, tag: "blockquote",
                  contained: Rope(kind: RopeAtom, text: s.toRunes()))

proc runCmdConfDumpParams*() =
  baseDump:
    if chalk == nil or extract == nil or paramKey notin extract:
      toDump = Rope(kind: RopeTaggedContainer, tag: "blockquote",
                    contained: Rope(kind: RopeAtom, text: "[]".toRunes()))
    else:
      toDump = boxToJson(extract[paramKey]).rawStrToRope(pre = false)

proc runCmdConfDumpCache*() =
  baseDump:
    if chalk == nil or extract == nil or cacheKey notin extract:
      runCmdConfDump()

    let
      componentInfo = selfChalk.extract[cacheKey]
      unpackedInfo  = unpack[OrderedTableRef[string, string]](componentInfo)

    for url, contents in unpackedInfo:
      toDump = toDump + htmlStringToRope("<h2> URL: " & url & "</h2>\n")
      toDump = toDump + Rope(kind: RopeTaggedContainer, tag: "blockquote",
                             contained: Rope(kind: RopeAtom,
                                             text: contents.toRunes()))
