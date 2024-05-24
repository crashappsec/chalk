##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk dump` command.

import std/posix
import ".."/[config, selfextract]

proc baseDump(toDump: string) {.noreturn.} =
  publish("confdump", toDump)
  quit(0)

proc runCmdConfDump*() =
  if len(getArgs()) > 0 or isatty(1) == 0:
    baseDump(getConfig())
  else:
    baseDump($code(getConfig()))

proc runCmdConfDumpParams*() =
  baseDump(pack(getParams()).boxToJson())

proc runCmdConfDumpCache*() =
  var
    r: Rope
    cells: seq[seq[Rope]]
  for url, contents in getCache():
    cells = @[@[pre(code(contents))]]
    r += cells.quickTable(noheaders = true, title = atom("URL: " & url))
  baseDump($r)

proc runCmdConfDumpAll*() =
  baseDump(getAllDumpJson())
