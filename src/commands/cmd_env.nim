##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk env` command.

import ../config, ../collect, ../reporting

template oneEnvItem(key: string, f: untyped) =
  let item = chalkConfig.envConfig.`get f`()
  if item.isSome():
    dict[key] = pack[string](item.get())

proc runCmdEnv*() =
  initCollection()



  doReporting()
