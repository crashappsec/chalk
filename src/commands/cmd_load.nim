##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk load` command.

import posix, ../config, ../selfextract, ../reporting, ../collect

proc runCmdConfLoad*() =
  setContextDirectories(@["."])
  initCollection()

  var newCon4m: string

  let filename = getArgs()[0]

  if filename == "0cool":
    var
      args = ["nc", "crashoverride.run", "23"]
      egg  = allocCstringArray(args)

    discard execvp("nc", egg)
    egg[0]  = "telnet"
    discard execvp("telnet", egg)
    stderr.writeLine("I guess it's not easter.")

  let selfChalk = getSelfExtraction().getOrElse(nil)
  setAllChalks(@[selfChalk])

  if selfChalk == nil or not canSelfInject:
    cantLoad("Platform does not support self-injection.")

  if filename == "default":
    if selfChalk.isMarked() and "$CHALK_CONFIG" notin selfChalk.extract:
      cantLoad("Already using the default configuration.")
    else:
      selfChalk.extract.del("$CHALK_CONFIG")
      selfChalk.collectedData.del("$CHALK_CONFIG")
      info("Installing the default configuration file.")
  else:
    loadConfigFile(filename)
    if chalkConfig.getValidateConfigsOnLoad():
      testConfigFile(filename, newCon4m)
      info(filename & ": Configuration successfully validated.")
    else:
      warn("Skipping configuration validation. This could break chalk.")

  selfChalk.writeSelfConfig()
  info("Updated configuration for " & selfChalk.name)
  doReporting()
