## The `chalk env` command.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import ../config, ../collect, ../reporting

template oneEnvItem(key: string, f: untyped) =
  let item = chalkConfig.envConfig.`get f`()
  if item.isSome():
    dict[key] = pack[string](item.get())

proc runCmdEnv*() =
  initCollection()



  doReporting()
