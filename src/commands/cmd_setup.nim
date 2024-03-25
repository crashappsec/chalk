##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk setup` command.

import ".."/[config, attestation_api, reporting, selfextract, util, collect]

proc runCmdSetup*() =
  setCommandName("setup")
  initCollection()

  let selfChalk = getSelfExtraction().getOrElse(nil)
  if selfChalk == nil:
    error("Platform does not support self-chalking.")
    return

  selfChalk.addToAllChalks()

  try:
    setupAttestation()
    doReporting()
    quitChalk(0)
  except:
    error(getCurrentExceptionMsg())
    quitChalk(1)
