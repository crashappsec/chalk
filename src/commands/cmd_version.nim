##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## The `chalk version` command.

import ".."/[
  attestation/utils,
  config,
  docker/exe,
  plugin_api,
  types,
  utils/semver,
]

proc default(version: Version, default = ""): string =
  if version == parseVersion("0"):
    return default
  return $version

proc runCmdVersion*() =
  var cells: seq[seq[string]]

  let
    client = getDockerClientVersion()
    server = getDockerServerVersion()
    buildx = getBuildXVersion()

  cells.add(@["Chalk Version", getChalkExeVersion()])
  if selfChalk != nil:
    cells.add(@["Chalk ID", selfChalk.callGetChalkId()])
  cells.add(@["Commit ID", getChalkCommitId()])
  cells.add(@["Build OS", hostOS])
  cells.add(@["Build CPU", hostCPU])
  cells.add(@["Build Date", CompileDate])
  cells.add(@["Build Time", CompileTime])
  cells.add(@["Docker Client", client.default()])
  cells.add(@["Docker Server", server.default()])
  cells.add(@["Buildx", buildx.default()])

  var table = cells.quickTable(verticalHeaders = true, borders = BorderTypical)

  table = table.setWidth(66)
  for item in table.search("th"):
    item.tpad(0).casing(CasingAsIs).left()

  publish("version", $table)
