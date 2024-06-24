##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[os]
import ".."/[config, util, semver]

var
  dockerExeLocation   = ""
  dockerClientVersion = parseVersion("0")
  dockerServerVersion = parseVersion("0")
  buildXVersion       = parseVersion("0")
  buildKitVersion     = parseVersion("0")

proc getDockerExeLocation*(): string =
  once:
    let
      dockerConfigPath = getOpt[string](getChalkScope(), "docker_exe")
      dockerExeOpt     = findExePath("docker",
                                     configPath      = dockerConfigPath,
                                     ignoreChalkExes = true)
    dockerExeLocation = dockerExeOpt.get("")
    if dockerExeLocation == "":
      warn("docker: no command found in PATH. `chalk docker` not available.")
  return dockerExeLocation

proc runDockerGetEverything*(args: seq[string], stdin = "", silent = true): ExecOutput =
  let exe = getDockerExeLocation()
  if not silent:
    trace("docker: " & exe & " " & args.join(" "))
    if stdin != "":
      trace("docker: stdin: \n" & stdin)
  result = runCmdGetEverything(exe, args, stdin)
  if not silent and result.exitCode > 0:
    trace(strutils.strip(result.stderr & result.stdout))
  return result

proc getBuildXVersion*(): Version =
  # Have to parse the thing to get compares right.
  once:
    if getEnv("DOCKER_BUILDKIT") == "0":
      return buildXVersion
    # examples:
    # github.com/docker/buildx v0.10.2 00ed17df6d20f3ca4553d45789264cdb78506e5f
    # github.com/docker/buildx 0.11.2 9872040b6626fb7d87ef7296fd5b832e8cc2ad17
    let version = runDockerGetEverything(@["buildx", "version"])
    if version.exitCode == 0:
      try:
        buildXVersion = getVersionFromLine(version.stdOut)
        trace("docker: buildx version: " & $(buildXVersion))
      except:
        dumpExOnDebug()
  return buildXVersion

proc getDockerClientVersion*(): Version =
  once:
    # examples:
    # Docker version 1.13.0, build 49bf474
    # Docker version 23.0.0, build e92dd87
    # Docker version 24.0.6, build ed223bc820
    let version = runDockerGetEverything(@["--version"])
    if version.exitCode == 0:
      try:
        dockerClientVersion = getVersionFromLine(version.stdOut)
        trace("docker: client version: " & $(dockerClientVersion))
      except:
        dumpExOnDebug()
  return dockerClientVersion

proc getDockerServerVersion*(): Version =
  once:
    let version = runDockerGetEverything(@["version"])
    if version.exitCode == 0:
      try:
        dockerServerVersion = getVersionFromLineWhich(
          version.stdOut.splitLines(),
          isAfterLineStartingWith = "Server:",
          contains                = "Version:",
        )
        trace("docker: server version: " & $(dockerServerVersion))
      except:
        dumpExOnDebug()
  return dockerServerVersion

proc hasBuildx*(): bool =
  return getBuildXVersion() > parseVersion("0")

var dockerInfo = ""
proc getDockerInfo*(): string =
  once:
    let output = runDockerGetEverything(@["info"])
    if output.exitCode != 0:
      error("docker: could not get docker info " & output.getStdErr())
    else:
      dockerInfo = output.getStdOut()
  return dockerInfo

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
            data = output.getStdOut.parseJson()
            name = data{"Name"}.getStr()
          if name != "":
            contextName = name
            trace("docker: context name: " & contextName)
        except:
          dumpExOnDebug()
  return contextName

proc getBuilderName(ctx: DockerInvocation): string =
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
      let output = runDockerGetEverything(args)
      if output.exitCode != 0:
        trace("docker: could not get buildx builder information: " & output.getStdErr())
      builderInfo = output.getStdOut()
  return builderInfo

proc getBuildKitVersion*(ctx: DockerInvocation): Version =
  once:
    let info = ctx.getBuilderInfo().toLower()
    try:
      buildKitVersion = getVersionFromLineWhich(
        info.splitLines(),
        contains = "buildkit",
      )
      trace("docker: buildkit version: " & $(buildKitVersion))
    except:
      dumpExOnDebug()
  return buildKitVersion

proc supportsBuildContextFlag*(ctx: DockerInvocation): bool =
  # https://github.com/docker/buildx/releases/tag/v0.8.0
  # which requires dockerfile syntax >=1.4
  # https://github.com/moby/buildkit/releases/tag/dockerfile%2F1.4.0
  # which is included in buildkit >= 0.10 as its released from same commit
  # https://github.com/moby/buildkit/releases/tag/v0.10.0
  # which in turn is included in docker server version >= 23
  # https://docs.docker.com/engine/release-notes/23.0/#2300
  return (
    getDockerClientVersion() >= parseVersion("21") and
    getDockerServerVersion() >= parseVersion("23") and
    getBuildXVersion()       >= parseVersion("0.8") and
    ctx.getBuildKitVersion() >= parseVersion("0.10")
  )

proc supportsCopyChmod*(): bool =
  # > the --chmod option requires BuildKit.
  # > Refer to https://docs.docker.com/go/buildkit/ to learn how to
  # > build images with BuildKit enabled
  return hasBuildx()

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
      raise newException(ValueError, "could not install binfmt " & output.getStdErr())
