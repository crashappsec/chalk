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

import std/[
  options,
  strutils,
]
import ".."/[
  utils/json,
  utils/semver,
]
import "../docker"/ids
import "./notice"
import "./chalk_platform"

type
  PodmanEnginePair* = object
    podman*: string
    buildah*: string

  PodmanCompatibilityFixture* = object
    pair*:        PodmanEnginePair
    fixtureId*:   string
    evidenceId*:  string

  PodmanHostResultKind* = enum
    phrSupported, phrRefused

  PodmanHostResult* = object
    case kind*: PodmanHostResultKind
    of phrSupported:
      platform*: ChalkPlatform
      engines*:  PodmanEnginePair
      fixtureId*: string
      evidenceId*: string
    of phrRefused:
      reason*: PodmanSkipReason

proc refusedHost(kind: PodmanSkipReasonKind): PodmanHostResult =
  return PodmanHostResult(
    kind:   phrRefused,
    reason: PodmanSkipReason(kind: kind),
  )

const podmanCompatibilityFixtures* = [
  PodmanCompatibilityFixture(
    pair: PodmanEnginePair(podman: "4.9.4", buildah: "1.33.7"),
    fixtureId: "podman-build-capabilities-v2",
    evidenceId: "gitlab-pipeline-3066209923",
  ),
  PodmanCompatibilityFixture(
    pair: PodmanEnginePair(podman: "5.0.3", buildah: "1.35.4"),
    fixtureId: "podman-build-capabilities-v2",
    evidenceId: "gitlab-pipeline-3066209923",
  ),
  PodmanCompatibilityFixture(
    pair: PodmanEnginePair(podman: "5.2.5", buildah: "1.37.5"),
    fixtureId: "podman-build-capabilities-v2",
    evidenceId: "gitlab-pipeline-3066209923",
  ),
  PodmanCompatibilityFixture(
    pair: PodmanEnginePair(podman: "5.4.2", buildah: "1.39.4"),
    fixtureId: "podman-build-capabilities-v2",
    evidenceId: "gitlab-pipeline-3066209923",
  ),
  PodmanCompatibilityFixture(
    pair: PodmanEnginePair(podman: "5.6.2", buildah: "1.41.5"),
    fixtureId: "podman-build-capabilities-v2",
    evidenceId: "gitlab-pipeline-3066209923",
  ),
  PodmanCompatibilityFixture(
    pair: PodmanEnginePair(podman: "6.1.4", buildah: "1.45.2"),
    fixtureId: "podman-build-capabilities-v2",
    evidenceId: "gitlab-pipeline-3066209923",
  ),
]

# Every pair above passed the same executable fixture on linux/amd64 and
# linux/arm64 in the recorded pipeline. Keep exact pairs: the results do not
# establish a version floor or support for combinations the matrix did not run.

proc parseStableEngineVersion(value: string): Option[string] =
  ## Accept only a complete stable x.y.z release. Exact fixture matching below
  ## rejects otherwise valid but unmeasured releases.
  let parts = value.split('.')
  if len(parts) != 3:
    return none(string)
  for part in parts:
    if part == "":
      return none(string)
    for c in part:
      if c notin {'0' .. '9'}:
        return none(string)
  return some(value)

proc parsePodmanEnginePair*(raw: string): Option[PodmanEnginePair] =
  try:
    let
      parsed = parseJson(raw)
      podman = parseStableEngineVersion(parsed{"version"}{"Version"}.getStr())
      buildah = parseStableEngineVersion(
        parsed{"host"}{"buildahVersion"}.getStr(),
      )
    if podman.isNone() or buildah.isNone():
      return none(PodmanEnginePair)
    return some(PodmanEnginePair(
      podman: podman.get(),
      buildah: buildah.get(),
    ))
  except:
    return none(PodmanEnginePair)

proc compatibilityFixture(pair: PodmanEnginePair):
                          Option[PodmanCompatibilityFixture] =
  for fixture in podmanCompatibilityFixtures:
    if fixture.pair == pair:
      return some(fixture)
  return none(PodmanCompatibilityFixture)

# Buildah 1.39.3 is the oldest release measured to accept a per-instruction
# `RUN --network=none`. Hosts below that measured threshold keep the plain RUN
# guard, so this optional optimization does not depend on an unmeasured parser.
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
    let engines = parsePodmanEnginePair(raw)
    if engines.isNone():
      return refusedHost(psrHostInfoInvalid)
    let fixture = compatibilityFixture(engines.get())
    if fixture.isNone():
      return refusedHost(psrEngineVersionUnsupported)
    return PodmanHostResult(
      kind:      phrSupported,
      platform:  target,
      engines:   engines.get(),
      fixtureId: fixture.get().fixtureId,
      evidenceId: fixture.get().evidenceId,
    )
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
