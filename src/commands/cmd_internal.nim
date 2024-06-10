##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[json]
import ".."/[config]

proc onbuild() =
  let data = readFile("/chalk.json")
  if not data.startsWith("{"):
    error("onbuild: not valid json in /chalk.json")
    return
  let
    existing = parseJson(data)
    updated  = newJObject()
  updated["EMBEDDED_CHALK"] = %(@[existing])
  if "METADATA_ID" in existing:
    updated["OLD_CHALK_METADATA_ID"]   = existing["METADATA_ID"]
  if "METADATA_HASH" in existing:
    updated["OLD_CHALK_METADATA_HASH"] = existing["METADATA_HASH"]
  writeFile("/chalk.json", $updated)

proc runCmdOnBuild*() =
  try:
    onbuild()
  except:
    error("onbuild: " & getCurrentExceptionMsg())
