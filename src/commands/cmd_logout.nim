##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk logout` command.

import ../collect, ../config, ../reporting, ../selfextract

proc runCmdLogout*() =
    info("Logging out of API, discarding saved tokens.")
    setCommandName("logout")
    initCollection()

    let selfChalk = getSelfExtraction().getOrElse(nil)

    if selfChalk == nil:
        error("Platform does not support self-chalking.")
        return

    selfChalk.addToAllChalks()

    # Logging out is really just deleting the OIDC access and refresh tokens

    if "$CHALK_API_KEY" in selfChalk.extract:
      selfChalk.extract.del("$CHALK_API_KEY")
      #selfChalk.collectedData.del("$CHALK_API_KEY")
      info("Removed $CHALK_API_KEY successfully.")

    if "$CHALK_API_REFRESH_TOKEN" in selfChalk.extract:
      selfChalk.extract.del("$CHALK_API_REFRESH_TOKEN")
      #selfChalk.collectedData.del("$CHALK_API_REFRESH_TOKEN")
      info("Removed $CHALK_API_REFRESH_TOKEN successfully.")

    info("Updated configuration for " & selfChalk.name)
    selfChalk.writeSelfConfig()
    info("API logout successful.")

    doReporting()
    return
