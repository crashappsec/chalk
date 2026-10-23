##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  plugin_api,
  run_management,
  types,
]

proc podmanGetChalkId(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  if chalk.extract != nil and "CHALK_ID" in chalk.extract:
    return unpack[string](chalk.extract["CHALK_ID"])
  var
    bytes  = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)
  for ch in bytes:
    preRes.add(ch)
  return preRes.idFormat()

proc podmanGetRunTimeArtifactInfo(self: Plugin, chalk: ChalkObj, ins: bool):
                                 ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artTypePodmanImage)
  if chalk.imageId != "":
    result.setIfNeeded("PODMAN_IMAGE_ID", chalk.imageId)

proc podmanWrite(self: Plugin, chalk: ChalkObj, enc: Option[string]) {.cdecl.} =
  discard

proc loadCodecPodman*() =
  newCodec("podman",
           rtArtCallback = RunTimeArtifactCb(podmanGetRunTimeArtifactInfo),
           getChalkId    = ChalkIdCb(podmanGetChalkId),
           handleWrite   = HandleWriteCb(podmanWrite),
           enabled       = true)
