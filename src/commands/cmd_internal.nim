##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  sequtils,
]
import ".."/[
  plugin_api,
  run_management,
  subscan,
  types,
  utils/json,
  utils/sets,
  utils/strings,
]

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

proc prepPostExec() =
  let
    toScan = attrGet[seq[string]]("exec.postexec.access_watch.scan_paths")
    codecs = attrGet[seq[string]]("exec.postexec.access_watch.scan_codecs")
    tmp    = attrGet[string]("exec.postexec.access_watch.prep_tmp_path")
  var paths = initHashSet[string]()
  withOnlyCodecs(getPluginsByName(codecs)):
    for chalk in runChalkSubScan(toScan, "extract").allChalks:
      paths.incl(chalk.fsRef)
  discard tryToWriteFile(
    tmp,
    paths.toSeq().join("\n"),
  )

proc runCmdPrepPostExec*() =
  try:
    prepPostExec()
  except:
    error("prep_postexec: " & getCurrentExceptionMsg())
