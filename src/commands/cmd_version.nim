##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk version` command.

import ../config

proc runCmdVersion*() =
  var txt = "<table><tbody>"

  txt &= "<tr><td>Chalk version</td><td>" & getChalkExeVersion() & "</td></tr>"
  txt &= "<tr><td>Commit ID</td><td>" & getChalkCommitID() & "</td></tr>"
  txt &= "<tr><td>Build OS</td><td>" & hostOS & "</td></tr>"
  txt &= "<tr><td>Build CPU</td><td>" & hostCPU & "</td></tr>"
  txt &= "<tr><td>Build Date</td><td>" & CompileDate & "</td></tr>"
  txt &= "<tr><td>Build Time</td><td>" & CompileTime & "</td></tr>"
  txt &= "</tbody></table>"

  publish("version", txt.stylize())
