##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk version` command.

import ../config

proc runCmdVersion*() =
  var s = newStyle(lpad=4, rpad=4, borders = [BorderNone])
  s.useTopBorder    = some(false)
  s.useBottomBorder = some(false)
  s.useLeftBorder   = some(false)
  s.useRightBorder  = some(false)
  s.useVerticalSeparator = some(false)
  s.useHorizontalSeparator = some(false)

  styleMap["table"]   = styleMap["table"].mergeStyles(s)
  var txt = """<table class=noborder>
               <colgroup><col width=30><col width=70><tbody>"""

  txt &= "<tr><td>Chalk version</td><td>" & getChalkExeVersion() & "</td></tr>"
  txt &= "<tr><td>Commit ID</td><td>" & getChalkCommitID() & "</td></tr>"
  txt &= "<tr><td>Build OS</td><td>" & hostOS & "</td></tr>"
  txt &= "<tr><td>Build CPU</td><td>" & hostCPU & "</td></tr>"
  txt &= "<tr><td>Build Date</td><td>" & CompileDate & "</td></tr>"
  txt &= "<tr><td>Build Time</td><td>" & CompileTime & "</td></tr>"
  txt &= "</tbody></table>"

  publish("version", txt.stylize())
