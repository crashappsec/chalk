##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk version` command.

import ".."/config

proc runCmdVersion*() =
  var cells: seq[seq[string]]

  cells.add(@["Chalk Version", getChalkExeVersion()])
  cells.add(@["Commit ID", getChalkCommitId()])
  cells.add(@["Build OS", hostOS])
  cells.add(@["Build CPU", hostCPU])
  cells.add(@["Build Date", CompileDate])
  cells.add(@["Build Time", CompileTime])

  var table = cells.quickTable(verticalHeaders = true, borders = BorderTypical)

  table = table.setWidth(66)
  for item in table.search("th"):
    item.tpad(0).casing(CasingAsIs).left()

  publish("version", $table)
