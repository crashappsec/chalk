##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk login` command.

import ../api, ../collect, ../config, ../reporting, ../selfextract, ../util

proc runCmdLogin*() =
    setCommandName("login")
    initCollection()

    let selfChalk = getSelfExtraction().getOrElse(nil)

    if selfChalk == nil:
        error("Platform does not support self-chalking.")
        return

    selfChalk.addToAllChalks()

    var 
        apiToken     = ""
        refreshToken = ""
    let use_api      = chalkConfig.getApiLogin()

    if use_api:
        info("Initiating API login...")
        (apiToken, refreshToken) = getChalkApiToken()
        if apiToken == "":
            trace("Login failed, no access token received.")
            quitChalk(1)
        trace("API & refresh tokens received: " & apiToken & " " & refreshToken)

        trace("Chalking access & refresh tokens values to self")
        let selfChalk = getSelfExtraction().get()
        selfChalk.extract["$CHALK_API_KEY"]             = pack(apiToken)
        selfChalk.extract["$CHALK_API_REFRESH_TOKEN"]   = pack(refreshToken)
        selfChalk.writeSelfConfig()
        
        info("API login successful.")
        doReporting()
        return
    else:
        info("Current configuration does not enable API, not proceeding with login.")
        quitChalk(1)
