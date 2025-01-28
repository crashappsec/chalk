##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import "../docker"/[collect, ids, exe, registry, nodes]
import ".."/[config, plugin_api, semver, chalkjson]

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
    chalk.collectLocalImage()

proc dockerGetRunTimeHostInfo(self: Plugin, chalks: seq[ChalkObj]): ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_DOCKER_CLIENT_VERSION", getDockerClientVersion().normalize())
  result.setIfNeeded("_DOCKER_SERVER_VERSION", getDockerServerVersion().normalize())
  result.setIfNeeded("_DOCKER_BUILDX_VERSION", getBuildXVersion().normalize())
  result.setIfNeeded("_DOCKER_INFO",           getDockerInfo())
  let ctx = dockerInvocation
  if ctx != nil:
    result.setIfNeeded("_DOCKER_USED_REGISTRIES",          getUsedRegistryConfigs())
    result.setIfNeeded("_DOCKER_BUILDER_BUILDKIT_VERSION", ctx.getBuildKitVersion().normalize())
    result.setIfNeeded("_DOCKER_BUILDER_INFO",             ctx.getBuilderInfo())
    result.setIfNeeded("_DOCKER_BUILDER_NODES_INFO",       ctx.getBuilderNodesInfo())
    result.setIfNeeded("_DOCKER_BUILDER_NODES_CONFIG",     ctx.getBuilderNodesConfigs().jsonTableToBox())

proc loadCodecDocker*() =
  # cant use getDockerExePath as that uses codecs to ignore chalk
  # wrappings hence we just check if anything docker is on PATH here
  let enabled = nimutils.findExePath("docker") != ""
  if not enabled:
    warn("Disabling docker codec as docker command is not available")
  newCodec("docker",
           rtArtCallback  = RunTimeArtifactCb(dockerGetRunTimeArtifactInfo),
           rtHostCallback = RunTimeHostCb(dockerGetRunTimeHostInfo),
           getChalkId     = ChalkIdCb(dockerGetChalkId),
           enabled        = enabled)
