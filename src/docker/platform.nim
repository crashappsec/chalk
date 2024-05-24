##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[tables]
import ".."/[config, util]
import "."/[dockerfile, exe, image, ids, inspect, manifest]

var defaultPlatforms = initTable[string, DockerPlatform]()
proc dockerProbeDefaultPlatforms*(): Table[string, DockerPlatform] =
  ## probe for default build target/build platforms
  ## this is needed to be able to correctly eval Dockerfile as these
  ## platforms will be prepopulated in buildx
  ## or we can use this to figure out default system target platform
  ## as this uses docker build to probe.
  ## Without probe well need to account for all the docker configs/env vars
  ## to correctly guage default build platform.
  result = defaultPlatforms

  once:
    let
      tmpTag     = chooseNewTag()
      envVars    = @[setEnv("DOCKER_BUILDKIT", "1")]
      probeFile  = """
  FROM busybox
  ARG BUILDPLATFORM
  ARG TARGETPLATFORM
  RUN echo "{\"BUILDPLATFORM\": \"$BUILDPLATFORM\", \"TARGETPLATFORM\": \"$TARGETPLATFORM\"}" > /platforms.json
  CMD cat /platforms.json
  """

    var data = ""

    try:
      withEnvRestore(envVars):
        let build  = runDockerGetEverything(@["build", "-t", tmpTag, "-f", "-", "."],
                                            probeFile)
        if build.getExit() != 0:
          warn("docker: could not probe build platforms: " & build.stdErr)
          return result

      let probe = runDockerGetEverything(@["run", "--rm", tmpTag])
      if probe.getExit() != 0:
        warn("docker: could not probe build platforms: " & probe.stdErr)
        return result

      data = probe.stdOut
      trace("docker: probing for build platforms: " & data)

    finally:
      discard runDockerGetEverything(@["rmi", tmpTag])

    if data == "":
      warn("docker: could not probe build platforms. Got empty output")
      return result

    let json = parseJson(data)
    for k, v in json.pairs():
      let value = v.getStr()
      if value == "":
        warn("docker: could not probe build platforms. Got empty value for: " & k)
        return result
      else:
        result[k] = parseDockerPlatform(value)

proc getSystemBuildPlatform(): DockerPlatform =
  return DockerPlatform(os: hostOs, architecture: hostCPU)

proc findDockerPlatform*(): DockerPlatform =
  return dockerProbeDefaultPlatforms().getOrDefault("TARGETPLATFORM", getSystemBuildPlatform())

proc findBaseImagePlatform*(ctx: DockerInvocation,
                            platformFlag = DockerPlatform(nil)): DockerPlatform =
  ## find platform for base image
  ## this can be either:
  ## * explicit platform provided in --platform CLI flag
  ## * FROM --platform=*
  ## * if base image has a single platform, thats the only possibility
  ##   even if it doesnt match the host platform
  ## * if base image has multiple platforms, we need to pick the
  ##   default host platform by probing one
  trace("docker: looking for base image platform")
  if platformFlag != nil:
    return platformFlag
  let baseSection = ctx.getBaseDockerSection()
  if baseSection.platform != nil:
    return baseSection.platform
  try:
    # TODO maybe this should be done after registry attempts?
    # multi-platform builds can pull base image from registry regardless of local cache
    trace("docker: attempting to inspect base image for: " & $(baseSection.image))
    let config = inspectImageJson(baseSection.image.asRepoRef())
    return DockerPlatform(os: config["Os"].getStr(), architecture: config["Architecture"].getStr())
  except:
    if hasBuildX():
      try:
        trace("docker: attempting to fetch only platform image manifest for: " & $(baseSection.image))
        let manifest = fetchOnlyImageManifest(baseSection.image)
        return manifest.platform
      except KeyError:
        trace("docker: could not find only platform manifest. looking for current host docker build platform manifest")
        let
          platform = findDockerPlatform()
          manifest = fetchImageManifest(baseSection.image, platform)
        return manifest.platform
    else:
      trace("docker: buildx is missing. pulling image locally for platform detection")
      let image =baseSection.image.asRepoRef()
      pullImage(image)
      let config = inspectImageJson(image)
      return DockerPlatform(os: config["Os"].getStr(), architecture: config["Architecture"].getStr())

proc findPlatformBinary(ctx: DockerInvocation, targetPlatform: DockerPlatform): string =
  # Mapping nim platform names to docker ones is a PITA. We need to
  # know the default target platform whenever --platform isn't
  # explicitly provided anyway, so we just ask Docker to tell us both
  # the native build platform, and the default target platform.

  # Note that docker does have some name normalization rules. For
  # instance, I think linux/arm/v7 and linux/arm64 are supposed to be
  # the same. We currently only ever self-identify with the later, but
  # you can match both options to point to the same binary with the
  # `arch_binary_locations` field.
  let buildPlatform  = getSystemBuildPlatform()
  if targetPlatform == buildPlatform:
    return getMyAppPath()

  let locOpt = getOpt[TableRef[string, string]](chalkConfig, "docker.arch_binary_locations")
  if locOpt.isNone():
    raise newException(ValueError, "docker.arch_binary_locations is not configured")

  let locInfo = locOpt.get()
  if $targetPlatform notin locInfo:
    raise newException(ValueError, "No chalk binary for " & $targetPlatform)

  result = locInfo[$targetPlatform].resolvePath()
  if not result.isExecutable():
    raise newException(
      ValueError,
      "Specified Chalk binary (" & result & ") for " &
      "TARGETPLATFORM (" & $targetPlatform & ") " &
      "is not executable."
    )

proc findAllPlatformsBinaries*(ctx: DockerInvocation, platforms: seq[DockerPlatform]): TableRef[DockerPlatform, string] =
  result = newTable[DockerPlatform, string]()
  for platform in platforms:
    result[platform] = ctx.findPlatformBinary(platform)

proc copyPerPlatform*(self: ChalkObj, platforms: seq[DockerPlatform]): TableRef[DockerPlatform, ChalkObj] =
  result = newTable[DockerPlatform, ChalkObj]()
  for platform in platforms:
    let copy = self.deepCopy()
    copy.collectedData.setIfNeeded("DOCKER_PLATFORM", $platform)
    result[platform] = copy

proc getAllPlatforms*(ctx: DockerInvocation): seq[DockerPlatform] =
  result = ctx.foundPlatforms
  if len(result) == 0:
    trace("docker: no --platform is provided")
    result.add(ctx.findBaseImagePlatform())
