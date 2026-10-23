##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Final base-image policy for the Podman build path.

import std/options
import "../docker"/ids
import ".."/utils/json
import "./binding"
import "./exec"
import "./image"
import "./notice"

type
  FinalBaseDecisionKind* = enum
    fbdAccept,
    fbdSkip

  FinalBaseDecision* = object
    case kind*: FinalBaseDecisionKind
    of fbdAccept:
      root*: BaseExec
    of fbdSkip:
      reason*: PodmanSkipReason

proc chalkCompatible(platform: DeclaredPlatform): bool =
  return platform.kind in {dpkKnown, dpkRequested} and
         platform.platform.os == "linux" and
         platform.platform.architecture == "amd64"

proc declaredPlatformSkip*(declared: DeclaredPlatform):
                           Option[PodmanSkipReason] =
  case declared.kind
  of dpkAbsent:
    return none(PodmanSkipReason)
  of dpkUnresolved:
    return some(PodmanSkipReason(kind: psrUnresolvedImagePlatform))
  of dpkRequested:
    if chalkCompatible(declared):
      return none(PodmanSkipReason)
    return some(PodmanSkipReason(kind: psrUnresolvedImagePlatform))
  of dpkKnown:
    if chalkCompatible(declared):
      return none(PodmanSkipReason)
    return some(PodmanSkipReason(kind: psrIncompatibleImagePlatform))

proc decideFinalBase*(rootImage, commandPlatform: string,
                      declared: DeclaredPlatform,
                      inspected: Option[InspectedBaseImage]):
                     FinalBaseDecision =
  ## Accept only a base whose inspected startup configuration remains attached
  ## to a compatible platform fact. Scratch has no inherited startup config.
  ## Podman exposes image metadata as the pre-build platform fact. This check
  ## does not detect a pre-existing image whose contents contradict its own
  ## metadata.
  let declaration = declaredPlatformSkip(declared)
  if declaration.isSome():
    return FinalBaseDecision(kind: fbdSkip, reason: declaration.get())

  if rootImage == "scratch":
    return FinalBaseDecision(
      kind: fbdAccept,
      root: BaseExec(
        entrypoint: JsonNode(nil),
        cmd:        JsonNode(nil),
        platform:   DeclaredPlatform(kind: dpkAbsent),
        binding:    BaseBinding(kind: bbScratch),
      ),
    )

  if inspected.isNone():
    return FinalBaseDecision(
      kind:   fbdSkip,
      reason: PodmanSkipReason(kind: psrImageBindingUnavailable),
    )

  let image = inspected.get()
  if not image.binding.validBinding():
    return FinalBaseDecision(
      kind:   fbdSkip,
      reason: PodmanSkipReason(kind: psrImageBindingUnavailable),
    )
  if chalkCompatible(image.platform):
    return FinalBaseDecision(
      kind: fbdAccept,
      root: BaseExec(
        entrypoint: image.entrypoint,
        cmd:        image.cmd,
        platform:   image.platform,
        binding:    image.binding,
      ),
    )

  let
    explicitAmd64 = commandPlatform != "" or declared.kind == dpkKnown
    reason =
      if image.platform.kind != dpkKnown:
        psrUnresolvedImagePlatform
      elif explicitAmd64:
        psrUnresolvedImagePlatform
      else:
        psrIncompatibleImagePlatform
  return FinalBaseDecision(
    kind:   fbdSkip,
    reason: PodmanSkipReason(kind: reason),
  )
