##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk env` command.
## Yes, this is all it (currently) does.

import ../collect, ../reporting

proc runCmdEnv*() =
  initCollection()
  doReporting()
