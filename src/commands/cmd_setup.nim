##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk setup` command.

import ".."/[
  attestation_api,
  collect,
  config,
  reporting,
  selfextract,
  run_management,
  types,
  utils/exec,
]

proc runCmdSetup*() =
  setFullCommandName("setup")
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
