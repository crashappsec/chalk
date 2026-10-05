##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.golden_images`: only allow building on and copying from
## allowlisted images. See docs/design-build-policy.md for the matching semantics.

import std/[
  strutils,
]
import "../.."/[
  docker/ids,
  types,
]
import ".."/[
  api,
  configuration,
]

type
  AllowedImage* = tuple
    kind:  string
    value: string

  MatchResult* = enum
    mrAllowed, mrDenied, mrUnknown

proc globMatch*(pattern, value: string): bool =
  ## shell-style glob where `*` matches any run of characters (including `/`)
  ## and `?` matches exactly one character
  var
    p        = 0
    v        = 0
    starP    = -1
    starV    = 0
  while v < len(value):
    if p < len(pattern) and (pattern[p] == '?' or pattern[p] == value[v]):
      inc(p)
      inc(v)
    elif p < len(pattern) and pattern[p] == '*':
      starP = p
      starV = v
      inc(p)
    elif starP != -1:
      p = starP + 1
      inc(starV)
      v = starV
    else:
      return false
  while p < len(pattern) and pattern[p] == '*':
    inc(p)
  return p == len(pattern)

proc normalizeRef(image: DockerImage): DockerImage =
  if image.repo == "":
    return image
  return image.normalize()

proc matchesGlob*(image: DockerImage, pattern: string): bool =
  # tag-less patterns match any tag
  let normalizedPattern = parseImage(pattern, defaultTag = "*").normalizeRef()
  var normalizedImage   = image.normalizeRef()
  # docker pulls :latest for a reference without tag or digest
  if normalizedImage.tag == "" and normalizedImage.digest == "":
    normalizedImage.tag = "latest"
  return (
    globMatch(normalizedPattern.repo, normalizedImage.repo) and
    globMatch(normalizedPattern.tag, normalizedImage.tag)
  )

proc matchesDigest*(image: DockerImage, digests: seq[string], value: string): bool =
  ## `digests` are all digests known for the image
  ## (e.g. the digest as written in the Dockerfile and the pinned one)
  let expected = parseImage(value, defaultTag = "")
  if expected.digest == "" or expected.digest notin digests:
    return false
  if expected.repo == "":
    return true
  return expected.normalizeRef().repo == image.normalizeRef().repo

proc checkImage*(image:   DockerImage,
                 digests: seq[string],
                 allowed: seq[AllowedImage],
                 ): tuple[result: MatchResult, reason: string] =
  if image.repo == "scratch":
    return (mrAllowed, "")
  var
    hasDigestRules = false
    unknownKinds   = newSeq[string]()
  for entry in allowed:
    case entry.kind
    of "glob":
      if image.matchesGlob(entry.value):
        return (mrAllowed, "")
    of "digest":
      hasDigestRules = true
      if image.matchesDigest(digests, entry.value):
        return (mrAllowed, "")
    else:
      if entry.kind notin unknownKinds:
        unknownKinds.add(entry.kind)
  if len(unknownKinds) > 0:
    return (mrUnknown, "unsupported allowlist entry kind(s): " & unknownKinds.join(", "))
  if hasDigestRules and len(digests) == 0:
    return (mrUnknown, "image digest could not be resolved to compare against allowed digests")
  return (mrDenied, "image is not in the list of allowed golden images")

type
  GoldenImagesConfig* = object
    checkCopyFrom*: bool
    allowed*:       seq[AllowedImage]
    message*:       string

proc check*(settings: GoldenImagesConfig, subjects: seq[PolicySubject]): seq[PolicyFinding] =
  for subject in subjects:
    if subject.source == "copy_from" and not settings.checkCopyFrom:
      continue
    let (res, reason) = subject.image.checkImage(subject.digests, settings.allowed)
    case res
    of mrAllowed:
      continue
    of mrDenied:
      var fullReason = reason
      if settings.message != "":
        fullReason &= ". " & settings.message
      result.add(subject.newFinding("golden_images", "violation", fullReason))
    of mrUnknown:
      result.add(subject.newFinding("golden_images", "error", reason))

proc loadGoldenImagesConfig*(): Option[GoldenImagesConfig] =
  if not policyBoolSetting(["golden_images", "enabled"], false):
    return none(GoldenImagesConfig)
  var settings = GoldenImagesConfig(
    checkCopyFrom: policyBoolSetting(["golden_images", "check_copy_from"], true),
    message:       policyStringSetting(["golden_images", "message"], ""),
  )
  for (kind, value) in policyPairsSetting(["golden_images", "allowed"]):
    settings.allowed.add((kind, value))
  return some(settings)

var loaded: GoldenImagesConfig

proc loadGoldenImages(): bool =
  let settings = loadGoldenImagesConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome()

proc checkGoldenImages(subjects: seq[PolicySubject]): seq[PolicyFinding] =
  loaded.check(subjects)

proc loadGoldenImagesRule*() =
  newPolicyRule("golden_images", loadGoldenImages, checkGoldenImages,
                requiresAllSubjects = true)
