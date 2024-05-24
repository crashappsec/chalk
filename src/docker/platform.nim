##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[tables, httpclient]
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

proc getSystemBuildPlatform*(): DockerPlatform =
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
  if $baseSection.image == "scratch":
    return getSystemBuildPlatform()
  try:
    # TODO maybe this should be done after registry attempts?
    # multi-platform builds can pull base image from registry regardless of local cache
    trace("docker: attempting to inspect base image for: " & $(baseSection.image))
    let config = inspectImageJson(baseSection.image.asRepoRef())
    return DockerPlatform(
      os:           config["Os"].getStr(),
      architecture: config["Architecture"].getStr(),
      variant:      config{"Variant"}.getStr(),
    )
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
      return DockerPlatform(
        os:           config["Os"].getStr(),
        architecture: config["Architecture"].getStr(),
        variant:      config{"Variant"}.getStr(),
      )

proc downloadPlatformBinary(targetPlatform: DockerPlatform): string =
  let
    config   = get[string](chalkConfig, "docker.download_arch_binary_url")
    url      = (config
                .replace("{version}",      getChalkExeVersion())
                .replace("{commit}",       getChalkCommitId())
                .replace("{os}",           targetPlatform.os)
                .replace("{architecture}", targetPlatform.architecture))
  trace("docker: downloading chalk binary from: " & url)
  let response = safeRequest(url)
  if response.code != Http200:
    trace("docker: while downloading chalk binary recieved: " & response.status)
    raise newException(
      ValueError,
      "Could not fetch chalk binary from '" & url & "' " &
      "due to " & response.status
    )

  let
    base = get[string](chalkConfig, "docker.arch_binary_locations_path")
    folder =
      if base == "":
        writeNewTempFile("")
      else:
        base.resolvePath().joinPath($targetPlatform)

  folder.createDir()
  result = folder.joinPath("chalk")

  if not result.tryToWriteFile(response.body()):
    raise newException(
      ValueError,
      "Could not save fetched chalk binary to: " & result
    )

  trace("docker: saved downloaded chalk binary for " & $targetPlatform & " to " & result)
  result.makeExecutable()

proc findPlatformBinaries(): TableRef[DockerPlatform, string] =
  result = newTable[DockerPlatform, string]()

  let
    basePath = get[string](chalkConfig, "docker.arch_binary_locations_path")
    locOpt   = getOpt[TableRef[string, string]](chalkConfig, "docker.arch_binary_locations")

  if basePath != "":
    let base = basePath.resolvePath()
    for path in walkDirRec(base, relative = true):
      let (platform, tail) = path.splitPath()
      if tail != "chalk":
        continue
      result[parseDockerPlatform(platform)] = base.joinPath(path)

  if locOpt.isNone():
    return

  # user-provided configs always take precedence of any auto discovered
  # platforms on disk
  let loc = locOpt.get()
  for platform, path in locOpt.get():
    result[parseDockerPlatform(platform)] = path.resolvePath()

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

  let pathByPlatform = findPlatformBinaries()
  if targetPlatform in pathByPlatform:
    let path = pathByPlatform[targetPlatform]
    if not path.isExecutable():
      raise newException(
        ValueError,
        "chalk binary (" & result & ") for " &
        "TARGETPLATFORM (" & $targetPlatform & ") " &
        "is not executable."
      )
    return path

  if get[bool](chalkConfig, "docker.download_arch_binary"):
    trace("docker: no chalk binary found for " &
          "TARGETPLATFORM (" & $targetPlatform & "). " &
          "Attempting to download chalk binary.")
    return downloadPlatformBinary(targetPlatform)

  raise newException(
    ValueError,
    "no chalk binary found for " &
    "TARGETPLATFORM (" & $targetPlatform & ")."
  )

proc findAllPlatformsBinaries*(ctx: DockerInvocation, platforms: seq[DockerPlatform]): TableRef[DockerPlatform, string] =
  result = newTable[DockerPlatform, string]()
  for platform in platforms:
    result[platform] = ctx.findPlatformBinary(platform)

proc doesBuilderSupportPlatform*(ctx: DockerInvocation, platform: DockerPlatform): bool =
  let info = ctx.getBuilderInfo()
  for line in info.splitLines():
    if line.startsWith("Platforms: "):
      let platforms = line.split(maxsplit = 1)[1].split(Whitespace + {','})
      for p in platforms:
        if p != "":
          if parseDockerPlatform(p) == platform:
            return true
      return false
  raise newException(
    ValueError,
    "could not find platforms for buildx builder"
  )

proc copyPerPlatform*(self: ChalkObj, platforms: seq[DockerPlatform]): TableRef[DockerPlatform, ChalkObj] =
  result = newTable[DockerPlatform, ChalkObj]()
  for platform in platforms:
    let copy = self.deepCopy()
    copy.collectedData.setIfNeeded("DOCKER_PLATFORM", $(platform.normalize()))
    copy.platform = platform
    result[platform] = copy

proc getAllPlatforms*(ctx: DockerInvocation): seq[DockerPlatform] =
  result = ctx.foundPlatforms
  if len(result) == 0:
    trace("docker: no --platform is provided")
    result.add(ctx.findBaseImagePlatform())
