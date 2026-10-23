##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Host policy decisions for the Podman build path.
##
## These are pure functions over `podman info` output. They live here rather
## than in build.nim so they can be unit tested without linking the whole Chalk
## runtime.

import std/options
import ".."/[
  utils/json,
  utils/semver,
]
import "../docker"/ids
import "./notice"
import "./chalk_platform"

type
  PodmanHostResultKind* = enum
    phrSupported, phrRefused

  PodmanHostResult* = object
    case kind*: PodmanHostResultKind
    of phrSupported:
      platform*: ChalkPlatform
    of phrRefused:
      reason*: PodmanSkipReason

proc refusedHost(kind: PodmanSkipReasonKind): PodmanHostResult =
  return PodmanHostResult(
    kind:   phrRefused,
    reason: PodmanSkipReason(kind: kind),
  )

# TODO(podman-version-floor): the host check below also required Podman 5.8.2
# and Buildah 1.43.1 by exact string equality -- the versions in the one pinned
# CI fixture the original demo was validated against, which rejected 5.8.1 and
# every release newer than 5.8.2 alike. Removed so the gate covers only host
# properties we actually depend on. A real minimum still has to be measured;
# see REMAINING_TODO.txt section 6 for the features to test against and the
# method. Until then a too-old host fails its injected build and falls back to
# the original command (failOpenOriginal), costing a wasted build rather than
# producing a wrong image.

# The oldest Buildah we have ACTUALLY VERIFIED accepts a per-instruction
# `RUN --network=none`, not the oldest that supports it. Verified by hand on
# 1.39.3 in two independent environments. Lowering this is a measurement task,
# not a guess -- see REMAINING_TODO.txt section 6. Erring high is safe: an
# older host simply keeps the plain RUN it has today.
const verifiedRunNetworkBuildah = "1.39.3"

proc checkPodmanHost*(raw: string, target: ChalkPlatform): PodmanHostResult =
  ## Returns the platform the host will build for when the command named none,
  ## or a fixed refusal if this host is outside the supported envelope.
  ##
  ## `raw` is the stdout of `podman info --format json`.
  try:
    let
      parsed = parseJson(raw)
      host   = parsed{"host"}
      osName = host{"os"}.getStr()
      arch   = host{"arch"}.getStr()
      remote = host{"serviceIsRemote"}.getBool(false)
    if osName == "" or arch == "":
      return refusedHost(psrHostInfoInvalid)
    let platform = parseDeclaredPlatform(osName & "/" & arch)
    if platform.kind != dpkKnown:
      return refusedHost(psrHostInfoInvalid)
    if platform.platform.os != "linux":
      return refusedHost(psrUnsupportedHostOs)
    let hostPlatform = chalkPlatformOf(platform.platform)
    if hostPlatform.isNone():
      return refusedHost(psrUnsupportedHostArch)
    if hostPlatform.get() != target:
      return refusedHost(psrHostPlatformMismatch)
    # A remote service builds on another machine, where the local paths we pass
    # via --build-context and --iidfile do not exist. That one is a real limit.
    if remote:
      return refusedHost(psrRemoteHost)
    # NOTE: this used to also require host.security.rootless. Like the version
    # pins, that was a property of the "hosted-rootless" CI fixture the demo was
    # validated against, not a capability we depend on -- nothing in the derived
    # Containerfile cares whether buildah runs rootless, and rootful podman in a
    # privileged CI container is a completely ordinary way to build. Requiring
    # it silently refused to instrument exactly that case.
    #
    return PodmanHostResult(kind: phrSupported,
                            platform: target)
  except:
    return refusedHost(psrHostInfoInvalid)

proc guardCanSkipNetwork*(raw: string): bool =
  ## Whether the injected reserved-path guard may be emitted as
  ## `RUN --network=none`.
  ##
  ## The guard is a pure filesystem test, but podman sets up a network
  ## namespace for every RUN, and that setup is what fails in restricted CI
  ## containers where pasta/slirp4netns cannot start -- taking the whole
  ## injected build down with it. Buildah parses the per-instruction flag
  ## natively, but an older one would treat it as a syntax error and fail every
  ## derived Containerfile, which is worse than the problem being solved. So
  ## this is feature detection, deliberately conservative.
  ##
  ## `raw` is the stdout of `podman info --format json`.
  try:
    let
      parsed  = parseJson(raw)
      buildah = parsed{"host"}{"buildahVersion"}.getStr()
    if buildah == "":
      return false
    return parseVersion(buildah) >= parseVersion(verifiedRunNetworkBuildah)
  except:
    return false
