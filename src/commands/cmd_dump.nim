##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk dump` command.

import ../config, ../selfextract

const
  configKey = "$CHALK_CONFIG"
  paramKey  = "$CHALK_SAVED_COMPONENT_PARAMETERS"

proc runCmdConfDump*() =
  var
    toDump  = defaultConfig
    chalk   = getSelfExtraction().getOrElse(nil)
    extract = if chalk != nil: chalk.extract else: nil
    params  = chalkConfig.dumpConfig.getParams()

  if params:
    if chalk == nil or extract == nil or paramKey notin extract:
      toDump = "[]\n"
    else:
      toDump = boxToJson(extract[paramKey])
  else:
    if chalk != nil and extract != nil and configKey in extract:
      toDump = unpack[string](extract[configKey])

  publish("confdump", toDump)
