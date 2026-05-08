##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import "."/[
  chalkjson,
  plugin_api,
  plugins/system,
  run_management,
  selfextract,
  subscan,
  types,
  utils/files,
]

proc copySelfConfigForArch*(path: string, os: string, arch: string): string =
  let
    platform = os & "/" & arch
    dir      = getNewTempDir("chalk-", "-" & os & "-" & arch)
    tmp      = dir.joinPath("chalk-" & os & "-" & arch)
  copyFile(path, tmp)
  chmodFilePermissions(tmp, "0755")
  var platformChalk: ChalkObj
  withOnlyCodecs(getNativeCodecs(os = os)):
    for i in runChalkSubScan(@[tmp], "extract").allChalks:
      if not i.isChalk():
        raise newException(ValueError, "Found chalk in " & tmp & " for " & platform & " is not a chalk executable")
      if i.validateMetaData() notin [vOk, vSignedOk]:
        raise newException(ValueError, "Found chalk in " & tmp & " for " & platform & " could not be validated")
      platformChalk = i
      break
  if platformChalk == nil:
    raise newException(ValueError, "Could not find any chalks in " & tmp & " for " & platform)
  if not selfChalk.writeSelfConfigToAnotherChalk(platformChalk):
    raise newException(ValueError, "Could not copy self chalkmark to " & tmp & " for " & platform)
  return tmp
