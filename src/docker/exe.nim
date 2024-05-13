##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[os]
import ".."/[config, util, semver]

var
  buildXVersion     = parseVersion("0")
  dockerVersion     = parseVersion("0")
  dockerExeLocation = ""

proc getDockerExeLocation*(): string =
  once:
    let
      dockerConfigPath = getOpt[string](chalkConfig, "docker_exe")
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

proc getDockerVersion*(): Version =
  once:
    # examples:
    # Docker version 1.13.0, build 49bf474
    # Docker version 23.0.0, build e92dd87
    # Docker version 24.0.6, build ed223bc820
    let version = runDockerGetEverything(@["--version"])
    if version.exitCode == 0:
      try:
        dockerVersion = getVersionFromLine(version.stdOut)
        trace("docker: version: " & $(dockerVersion))
      except:
        dumpExOnDebug()

  return dockerVersion

template hasBuildx*(): bool =
  getBuildXVersion() > parseVersion("0")

template supportsBuildContextFlag*(): bool =
  # https://github.com/docker/buildx/releases/tag/v0.8.0
  getDockerVersion() >= parseVersion("21") and getBuildXVersion() >= parseVersion("0.8")

template supportsCopyChmod*(): bool =
  # > the --chmod option requires BuildKit.
  # > Refer to https://docs.docker.com/go/buildkit/ to learn how to
  # > build images with BuildKit enabled
  hasBuildx()
