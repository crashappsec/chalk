##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
]
import ".."/[
  types,
  n00b/subproc,
  utils/exe,
  utils/json,
  utils/semver,
  utils/sets,
  utils/strings,
]
import "."/[
  ids,
]

export subproc

var
  dockerExeLocation   = ""
  dockerClientVersion = parseVersion("0")
  dockerServerVersion = parseVersion("0")
  buildXVersion       = parseVersion("0")
  buildKitVersion     = parseVersion("0")
  frontendVersion     = none(Version)

proc getDockerExeLocation*(): string =
  once:
    let
      dockerConfigPath = attrGetOpt[string]("docker_exe")
      dockerExeOpt     = findExePath("docker",
                                     configPath      = dockerConfigPath,
                                     ignoreChalkExes = true)
    dockerExeLocation = dockerExeOpt.get("")
    if dockerExeLocation == "":
      warn("docker: no command found in PATH. `chalk docker` not available.")
  return dockerExeLocation

proc runDockerGetEverything*(args: seq[string],
                             stdin = "",
                             silent = true,
                             ): n00bProc =
  result = runCommand(
    getDockerExeLocation(),
    args,
    stdin   = stdin,
    verbose = not silent,
    capture = {StdOutFD, StdErrFD},
    proxy   = {StdInFD},
  )

proc getBuildXVersion*(): Version =
  once:
    if getDockerExeLocation() == "":
      return buildXVersion
    if getEnv("DOCKER_BUILDKIT") == "0":
      if dockerInvocation != nil and dockerInvocation.cmd == build and dockerInvocation.foundBuildx:
        trace("docker: DOCKER_BUILDKIT is disabled but explicitly running with buildx")
      else:
        return buildXVersion
    # examples:
    # github.com/docker/buildx v0.10.2 00ed17df6d20f3ca4553d45789264cdb78506e5f
    # github.com/docker/buildx 0.11.2 9872040b6626fb7d87ef7296fd5b832e8cc2ad17
    let version = runDockerGetEverything(@["buildx", "version"])
    if version.exitCode == 0:
      try:
        buildXVersion = getVersionFromLine(version.stdout)
        trace("docker: buildx version: " & $(buildXVersion))
      except:
        dumpExOnDebug()
  return buildXVersion

proc getDockerClientVersion*(): Version =
  once:
    if getDockerExeLocation() == "":
      return dockerClientVersion
    # examples:
    # Docker version 1.13.0, build 49bf474
    # Docker version 23.0.0, build e92dd87
    # Docker version 24.0.6, build ed223bc820
    let version = runDockerGetEverything(@["--version"])
    if version.exitCode == 0:
      try:
        dockerClientVersion = getVersionFromLine(version.stdout)
        trace("docker: client version: " & $(dockerClientVersion))
      except:
        dumpExOnDebug()
  return dockerClientVersion

proc getDockerServerVersion*(): Version =
  once:
    if getDockerExeLocation() == "":
      return dockerServerVersion
    let version = runDockerGetEverything(@["version"])
    if version.exitCode == 0:
      try:
        dockerServerVersion = getVersionFromLineWhich(
          version.stdout.splitLines(),
          isAfterLineStartingWith = "Server:",
          contains                = "Version:",
        )
        trace("docker: server version: " & $(dockerServerVersion))
      except:
        dumpExOnDebug()
  return dockerServerVersion

proc hasBuildX*(): bool =
  return getBuildXVersion() > parseVersion("0")

var dockerInfo = ""
proc getDockerInfo*(): string =
  once:
    if getDockerExeLocation() == "":
      return dockerInfo
    let output = runDockerGetEverything(@["info"])
    if output.exitCode != 0:
      error("docker: could not get docker info " & output.stderr)
    else:
      dockerInfo = output.stdout
  return dockerInfo

proc getDockerInfoSubList*(key: string): seq[string] =
  let lower = key.toLower()
  result = @[]
  var
    found  = false
    indent = 0
  for line in getDockerInfo().splitLines():
    if line.strip().toLower() == lower:
      found  = true
      indent = len(line) - len(line.strip(trailing = false))
      continue
    if not found:
      continue
    # all list entries are indented
    # so if a line has same indent as header we exhaused relevant lines
    if len(line) - len(line.strip(trailing = false)) <= indent:
      break
    result.add(line.strip())

proc readDockerHostFile*(path: string): string =
  # note that the docker socket can be mounted to a container where
  # chalk is running from hence we attempt to get the file content
  # via a docker run and mounting source path which will allow
  # us to get the content of file of the docker daemon host,
  # not where chalk is running
  let
    inner  = "/mnt" & path
    output = runDockerGetEverything(
      @[
        "run",
        "--entrypoint=cat",
        # note that --mount does not create the source path if one doesnt exist already
        # unlike --volume which creates a folder if one is not present already
        "--mount", "type=bind,source=" & path & ",target=" & inner,
        "busybox",
        inner,
      ],
      silent = false,
    )
  if output.exitCode != 0:
    raise newException(ValueError, "could not read " & path)
  trace("docker: read docker host's " & path)
  return output.stdout

proc readFirstDockerHostFile*(paths: seq[string]): tuple[path: string, content: string] =
  for path in paths.toHashSet():
    try:
      return (path, readDockerHostFile(path))
    except:
      continue
  raise newException(ValueError, "could not read any of " & $paths)

var contextName = "default"
proc getContextName(): string =
  once:
    # https://docs.docker.com/engine/release-notes/19.03/#19030
    let minimum = parseVersion("19.03")
    if getDockerServerVersion() >= minimum and getDockerClientVersion() >= minimum:
      let output = runDockerGetEverything(@["context", "inspect", "--format", "{{json .}}"])
      if output.exitCode == 0:
        try:
          let
            data = output.stdout.parseJson()
            name = data{"Name"}.getStr()
          if name != "":
            contextName = name
            trace("docker: context name: " & contextName)
        except:
          dumpExOnDebug()
  return contextName

proc getBuilderName(ctx: DockerInvocation): string =
  if ctx != nil and ctx.cmd == DockerCmd.build:
    if not ctx.foundBuildx:
      return getContextName()
    if ctx.foundBuilder != "":
      return ctx.foundBuilder
  return getEnv("BUILDX_BUILDER")

var builderInfo = ""
proc getBuilderInfo*(ctx: DockerInvocation): string =
  once:
    if hasBuildX():
      let name = ctx.getBuilderName()
      var args = @["buildx", "inspect", "--bootstrap"]
      if name != "":
        args.add(name)
      let output = runDockerGetEverything(args, silent = false)
      if output.exitCode != 0:
        trace("docker: could not get buildx builder information: " & output.stderr)
      builderInfo = output.stdout
  return builderInfo

proc getBuildKitVersion*(ctx: DockerInvocation): Version =
  once:
    let info = ctx.getBuilderInfo().toLower()
    if info != "":
      try:
        buildKitVersion = getVersionFromLineWhich(
          info.splitLines(),
          contains = "buildkit",
        )
        trace("docker: buildkit version: " & $(buildKitVersion))
      except:
        dumpExOnDebug()
  return buildKitVersion

proc getFrontendVersion*(ctx: DockerInvocation): Option[Version] =
  ## get buildkit frontend version
  ## * returns none if frontend is not specified
  ##   and default buildkit version will be used
  ## * returns "0" if the version could not be determined
  ## * return actual version otherwise
  result = frontendVersion
  once:
    if ctx == nil or ctx.cmd != DockerCmd.build:
      return
    let syntax = ctx.dfDirectives.getOrDefault(
      "syntax",
      ctx.foundBuildArgs.getOrDefault("BUILDKIT_SYNTAX", ""),
    )
    if syntax == "":
      return
    try:
      let
        image  = parseImage(syntax)
        output = runDockerGetEverything(@[
          "run",
          "--rm",
          $image,
          "-version",
        ])
      if output.exitCode != 0:
        trace("docker: could not get buildkint frontend version " & output.stderr)
        frontendVersion = some(parseVersion("0"))
      else:
        let version = getVersionFromLine(output.stdout)
        trace("docker: frontend version: " & $version)
        frontendVersion = some(version)
      return frontendVersion
    except:
      dumpExOnDebug()
      frontendVersion = some(parseVersion("0"))
  return frontendVersion

var dockerAuth = newJObject()
proc getDockerAuthConfig*(): JsonNode =
  once:
    let path = "~/.docker/config.json"
    try:
      let data = tryToLoadFile(path.resolvePath())
      if data != "":
        dockerAuth = parseJson(data)
      else:
        trace("docker: no auth config file at " & path)
    except:
      trace("docker: could not read docker auth config file " & path & " due to: " & getCurrentExceptionMsg())
  return dockerAuth

proc supportsBuildContextFlag*(ctx: DockerInvocation): bool =
  # https://github.com/docker/buildx/releases/tag/v0.8.0
  # which requires dockerfile syntax >=1.4
  # https://github.com/moby/buildkit/releases/tag/dockerfile%2F1.4.0
  # which is included in buildkit >= 0.10 as its released from same commit
  # https://github.com/moby/buildkit/releases/tag/v0.10.0
  # which in turn is included in docker server version >= 23
  # https://docs.docker.com/engine/release-notes/23.0/#2300
  let frontend = getFrontendVersion(ctx)
  return (
    getDockerClientVersion() >= parseVersion("21") and
    getDockerServerVersion() >= parseVersion("23") and
    getBuildXVersion()       >= parseVersion("0.8") and
    ctx.getBuildKitVersion() >= parseVersion("0.10") and
    (frontend.isNone() or
     frontend.get()          >= parseVersion("1.4"))
  )

proc supportsCopyChmod*(): bool =
  # > the --chmod option requires BuildKit.
  # > Refer to https://docs.docker.com/go/buildkit/ to learn how to
  # > build images with BuildKit enabled
  return hasBuildX()

proc supportsInspectJsonFlag*(): bool =
  # https://github.com/docker/cli/pull/2936
  return getDockerClientVersion() >= parseVersion("22")

proc supportsMultiStageBuilds*(): bool =
  # https://docs.docker.com/engine/release-notes/17.05/
  return getDockerServerVersion() >= parseVersion("17.05")

proc supportsMetadataFile*(ctx: DockerInvocation): bool =
  # docker buildx build
  if ctx.foundBuildx:
    # https://github.com/docker/buildx/releases/tag/v0.6.0
    return getBuildXVersion() >= parseVersion("0.6")
  else:
    # docker>=23 (technically was changed in 22-rc)
    # docker build is an alias to docker buildx build therefore
    # any buildx flags are also added to build command
    # https://docs.docker.com/engine/release-notes/23.0/#2300
    return (
      getBuildXVersion() >= parseVersion("0.6") and
      getDockerClientVersion() >= parseVersion("22")
    )

proc installBinFmt*() =
  once:
    # https://docs.docker.com/build/building/multi-platform/#qemu-without-docker-desktop
    info("docker: installing binfmt for multi-platform builds")
    let output = runDockerGetEverything(@[
      "run",
      "--privileged",
      "--rm",
      "tonistiigi/binfmt",
      "--install",
      "all",
    ])
    if output.exitCode != 0:
      raise newException(ValueError, "could not install binfmt " & output.stderr)
