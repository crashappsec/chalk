##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk env` command.
## Yes, this is all it (currently) does.

import std/[
  os
]
import ".."/[
  collect,
  reporting,
  types,
  chalkjson,
  run_management,
  plugin_api,
  utils/files,
]

# TODO create generic mechanism in codecs to collect runtime self-chalkmark
# as there is some overlap between
# * exec for docker entrypoint
# * serverless zips running in lambda
proc collectServerlessChalkMark() =
  let
    TASK_PATH                = getEnv("TASK_PATH")
    AWS_LAMBDA_RUNTIME_API   = getEnv("AWS_LAMBDA_RUNTIME_API")
    AWS_LAMBDA_FUNCTION_NAME = getEnv("AWS_LAMBDA_FUNCTION_NAME")

  if TASK_PATH == "" or AWS_LAMBDA_RUNTIME_API == "" or AWS_LAMBDA_FUNCTION_NAME == "":
    trace("env: not serverless environment")
    return

  let chalkPath = TASK_PATH.joinPath("chalk.json")

  trace("env: looking for a chalk file at: " & chalkPath)
  withFileStream(chalkPath, mode = fmRead, strict = false):
    if stream == nil:
      error(chalkPath & ": could not read chalkmark")
      return

    info("env: extracting chalk mark from " & chalkPath)
    try:
      let
        extract = stream.extractOneChalkJson(TASK_PATH)
        chalk   = newChalk(name          = AWS_LAMBDA_RUNTIME_API,
                           fsRef         = TASK_PATH,
                           resourceType  = {ResourcePid, ResourceFile},
                           extract       = extract,
                           collectedData = extract.copy(),
                           codec         = getPluginByName("zip"))
      chalk.addToAllChalks()
    except:
      error(chalkPath & ": not a valid chalkmark - " & getCurrentExceptionMsg())

proc runCmdEnv*() =
  initCollection()
  collectServerlessChalkMark()
  doReporting()
