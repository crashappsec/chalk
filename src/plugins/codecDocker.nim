##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import "../docker"/[collect, ids]
import ".."/[config, plugin_api]

const markLocation = "/chalk.json"

proc dockerGetChalkId(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  if chalk.extract != nil and "CHALK_ID" in chalk.extract:
    return unpack[string](chalk.extract["CHALK_ID"])
  return dockerGenerateChalkId()

proc dockerGetRunTimeArtifactInfo(self: Plugin, chalk: ChalkObj, ins: bool):
                                 ChalkDict {.exportc, cdecl.} =
  result = ChalkDict()
  # docker chalks are collected while scanning however some
  # metadata can change since the scan such as for docker push
  # with repo digests and so we need to collect updated image metdata.
  # Note this only applies to images and not containers and so we only
  # recollect image metadata
  if ResourceContainer notin chalk.resourceType:
    chalk.collectImage()

proc loadCodecDocker*() =
  # cant use getDockerExePath as that uses codecs to ignore chalk
  # wrappings hence we just check if anything docker is on PATH here
  let enabled = nimutils.findExePath("docker") != ""
  if not enabled:
    warn("Disabling docker codec as docker command is not available")
  newCodec("docker",
           rtArtCallback = RunTimeArtifactCb(dockerGetRunTimeArtifactInfo),
           getChalkId    = ChalkIdCb(dockerGetChalkId),
           enabled       = enabled)
