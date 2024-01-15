##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk setup` command.

import ../config, ../attestation, ../reporting, ../selfextract, ../util,
       ../collect

proc runCmdSetup*(gen, load: bool) =
  setCommandName("setup")
  initCollection()

  let selfChalk = getSelfExtraction().getOrElse(nil)

  if selfChalk == nil:
    error("Platform does not support self-chalking.")
    return

  selfChalk.addToAllChalks()
  info("Ensuring cosign is present to setup attestation.")

  if getCosignLocation(downloadCosign = true) == "":
    quitChalk(1)
  if load:
    # If we fall back to 'gen' we don't want attemptToLoadKeys
    # to give an error when we don't find keys.
    if attemptToLoadKeys(silent=gen):
      doReporting()
      return
    let
      base = getKeyFileLoc()


    if not gen:
      error("Failed to load signing keys. Aborting.")
      quitChalk(1)
    elif fileExists(base & ".pub") or fileExists(base & ".key"):
      error("Keypair failed to load, but key file(s) are present. Move or " &
            "remove in order to regenerate.")
      quitChalk(1)

  if attemptToGenKeys():
    doReporting()
    return
  else:
    error("Failed to generate signing keys. Aborting.")
    quitChalk(1)
    