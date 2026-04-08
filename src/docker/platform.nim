##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  collect,
  config,
  plugin_api,
  plugins/system,
  run_management,
  selfextract,
  subscan,
  types,
  utils/envvars,
  utils/exe,
  utils/files,
  utils/http,
  utils/json,
  utils/uri,
]
import "."/[
  dockerfile,
  exe,
  ids,
  image,
  inspect,
  manifest,
]

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
    trace("docker: probing for build platforms")
    let
      tmpTag     = chooseNewTag()
      envVars    = @[setEnv("DOCKER_BUILDKIT", "1")]
      probeFile  = """
FROM scratch
ARG BUILDPLATFORM
ARG TARGETPLATFORM
ENV BUILDPLATFORM=$BUILDPLATFORM
ENV TARGETPLATFORM=$TARGETPLATFORM
"""
    trace("docker: probing platform with: \n" & probeFile)

    var data = ""

    try:
      withEnvRestore(envVars):
        let build  = runDockerGetEverything(@["build", "-t", tmpTag, "-f", "-", "."],
                                            probeFile)
        if build.getExit() != 0:
          warn("docker: could not probe build platforms: " & build.stderr)
          return result

      let probe = runDockerGetEverything(@["image", "inspect", tmpTag])
      if probe.getExit() != 0:
        warn("docker: could not probe build platforms: " & probe.stderr)
        return result

      data = probe.stdout

    finally:
      discard runDockerGetEverything(@["rmi", tmpTag])
      trace("docker: done probing for build platforms")

    if data == "":
      warn("docker: could not probe build platforms. Got empty output")
      return result

    try:
      let
        inspected = (
          parseJson(data)
          .assertIs(JArray, "inspect result should be an array")
          .assertHasLen("no inspect results")
        )
        image  = inspected[0].assertIs(JObject, "inspected image should be an object")
        config = image{"Config"}.assertIs(JObject, "config should be an object")
        envs   = config{"Env"}.assertIs(JArray, "env should be an array")
      var tmp  = initTable[string, DockerPlatform]()
      for env in envs:
        let
          kv     = env.getStr()
          (k, v) = kv.splitBy("=")
        if k.startsWith("TARGET") or k.startsWith("BUILD"):
          trace("docker: " & kv)
          if v != "":
            tmp[k] = parseDockerPlatform(v)
      if len(tmp) > 0:
        defaultPlatforms = tmp
        result           = tmp
      else:
        warn("docker: could not probe docker build platforms. all args were empty")
    except:
      warn("docker: could not parse probe inspect results: " & getCurrentExceptionMsg())

proc findDockerPlatform*(): DockerPlatform =
  return dockerProbeDefaultPlatforms().getOrDefault("TARGETPLATFORM", getSystemBuildPlatform())

proc findBaseImagePlatform*(ctx: DockerInvocation): DockerPlatform =
  ## find platform for base image
  ## this can be either:
  ## * explicit platform provided in --platform CLI flag
  ## * FROM --platform=*
  ## * if base image has a single platform, thats the only possibility
  ##   even if it doesnt match the host platform
  ## * if base image has multiple platforms, we need to pick the
  ##   default host platform by probing one
  trace("docker: looking for base image platform")
  let baseSection = ctx.getBaseDockerSection()
  if baseSection.platform != nil:
    trace("docker: base image section defines platform")
    return baseSection.platform
  if $baseSection.image == "scratch":
    trace("docker: image is scratch. looking up system build platform")
    return getSystemBuildPlatform()
  try:
    # TODO maybe this should be done after registry attempts?
    # multi-platform builds can pull base image from registry regardless of local cache
    trace("docker: attempting to inspect base image for: " & $(baseSection.image))
    let config = inspectImageJson(baseSection.image.asRepoRef())
    result = DockerPlatform(
      os:           config["Os"].getStr(),
      architecture: config["Architecture"].getStr(),
      variant:      config{"Variant"}.getStr(),
    )
    trace("docker: found image locally. using its platform " & $result)
  except:
    # TODO still need to check buildx?
    if hasBuildX():
      try:
        trace("docker: attempting to fetch only platform image manifest for: " & $(baseSection.image))
        let manifest = (
          fetchListOrImageManifest(baseSection.image)
          .allImages()
          .filterKnownPlatforms()
          .one()
        )
        trace("docker: found image manifest. using " & $manifest.platform)
        return manifest.platform
      except KeyError:
        let platform = findDockerPlatform()
        trace("docker: could not find only platform manifest. looking for current host docker build platform manifest " & $platform)
        let manifest = fetchImageManifest(baseSection.image, platform)
        return manifest.platform
    else:
      trace("docker: buildx is missing. pulling image locally for platform detection")
      let image = baseSection.image.asRepoRef()
      pullImage(image)
      let config = inspectImageJson(image)
      result = DockerPlatform(
        os:           config["Os"].getStr(),
        architecture: config["Architecture"].getStr(),
        variant:      config{"Variant"}.getStr(),
      )
      trace("docker: found platform from pulled image " & $result)

iterator platformUrls(targetPlatform: DockerPlatform): string =
  let platform = targetPlatform.normalize()
  for config in attrGet[seq[string]]("docker.download_arch_binary_urls"):
    yield (
      config
      .replace("{version}",      getChalkExeVersion())
      .replace("{commit}",       getChalkCommitId())
      .replace("{os}",           platform.os)
      .replace("{architecture}", platform.architecture)
      .replace("{variant}",      platform.variant)
    )

proc downloadPlatformBinary(targetPlatform: DockerPlatform): string =
  let
    platform = targetPlatform.normalize()
    path     = attrGet[string]("docker.arch_binary_locations_path").resolvePath()
  var
    statuses: seq[string] = @[]
    urls:     seq[string] = @[]

  path.createDir()

  # attempt to donwload from all urls in the order they are defined
  for url in platform.platformUrls():
    let name = parseUri(url).path.splitPath().tail
    urls.add(url)
    trace("docker: downloading chalk binary from: " & url)

    var body: string
    try:
      let response = safeRequest(
        url,
        retries = 2,
        acceptStatusCodes = [200..200],
      )
      body = response.body()
    except:
      trace("docker: while downloading chalk binary recieved: " & getCurrentExceptionMsg())
      statuses.add(getCurrentExceptionMsg())
      continue

    result = path.joinPath(name)
    if not result.tryToWriteFile(body):
      raise newException(
        ValueError,
        "Could not save fetched chalk binary to: " & result
      )

    trace("docker: saved downloaded chalk binary for " & $platform & " to " & result)
    result.makeExecutable()
    return

  raise newException(
    ValueError,
    "Could not fetch chalk binary from any of '" & $urls & "' " &
    "due to " & $statuses
  )

proc findExistingPlatformBinary(platform: DockerPlatform): string =
  let base = attrGet[string]("docker.arch_binary_locations_path").resolvePath()
  for url in platform.platformUrls():
    let
      name = parseUri(url).path.splitPath().tail
      path = base.joinPath(name)
    if path.fileExists() and path.isExecutable():
      trace("docker: found existing chalk binary " & path & " for TARGETPLATFORM (" & $platform & ")")
      return path

proc copyWithSelfConfig(path: string, platform: DockerPlatform): string =
  let tmp = getNewTempDir(
     "chalk-",
     "-" & ($platform).replace("/", "_").replace(".", "_"),
  ).joinPath("chalk")
  copyFile(path, tmp)
  setFilePermissions(tmp, {
    # 0755
    fpUserExec,
    fpUserWrite,
    fpUserRead,
    fpGroupExec,
    fpGroupRead,
    fpOthersExec,
    fpOthersRead,
  })
  var platformChalk: ChalkObj
  withOnlyCodecs(getNativeCodecs(platform = platform.os)):
    for i in runChalkSubScan(@[tmp], "extract").allChalks:
      if not i.isChalk():
        raise newException(ValueError, "Found chalk in " & tmp & " for TARGETPLATFORM (" & $platform & ") is not a chalk executable")
      if i.validateMetaData() notin [vOk, vSignedOk]:
        raise newException(ValueError, "Found chalk in " & tmp & " for TARGETPLATFORM (" & $platform & ") could not be validated")
      platformChalk = i
      break
  if platformChalk == nil:
    raise newException(ValueError, "Could not find any chalks in " & tmp & " for TARGETPLATFORM (" & $platform & ")")
  if not selfChalk.writeSelfConfigToAnotherChalk(platformChalk):
    raise newException(ValueError, "Could not copy self chalkmark to " & tmp & " for TARGETPLATFORM (" & $platform & ")")
  return tmp

proc findPlatformBinary(ctx: DockerInvocation, targetPlatform: DockerPlatform): string =
  # Mapping nim platform names to docker ones is a non-trivial. We need to
  # know the default target platform whenever --platform isn't
  # explicitly provided anyway, so we just ask Docker to tell us both
  # the native build platform, and the default target platform.
  let buildPlatform  = getSystemBuildPlatform()
  if targetPlatform == buildPlatform:
    return getMyAppPath().copyWithSelfConfig(targetPlatform)

  let path = findExistingPlatformBinary(targetPlatform)
  if path != "":
    return path.copyWithSelfConfig(targetPlatform)

  if attrGet[bool]("docker.download_arch_binary"):
    trace("docker: no chalk binary found for " &
          "TARGETPLATFORM (" & $targetPlatform & "). " &
          "Attempting to download chalk binary.")
    return downloadPlatformBinary(targetPlatform).copyWithSelfConfig(targetPlatform)

  raise newException(
    ValueError,
    "no chalk binary found for " &
    "TARGETPLATFORM (" & $targetPlatform & ")."
  )

proc findAllPlatformsBinaries*(ctx: DockerInvocation, platforms: seq[DockerPlatform]): TableRef[DockerPlatform, string] =
  result = newTable[DockerPlatform, string]()
  for platform in platforms:
    try:
      result[platform] = ctx.findPlatformBinary(platform)
    except:
      error("docker: could not get chalk binary for TARGETPLATFORM (" & $platform & ") " &
            getCurrentExceptionMsg())
      dumpExOnDebug()

proc doesBuilderSupportPlatform*(ctx: DockerInvocation, platform: DockerPlatform): bool =
  let info = ctx.getBuilderInfo()
  for line in info.splitLines():
    if line.startsWith("Platforms: "):
      let platforms = line.split(maxsplit = 1)[1].splitAnd(Whitespace + {','})
      trace("docker: checking if builder can build " & $platform & ". " &
            "It supports: " & $platforms)
      for p in platforms:
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
    copy.myCodec = self.myCodec
    copy.platform = platform
    result[platform] = copy
