##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Base image selection and immutable binding for Podman builds.
##
## The pull policy and effective platform determine which image Podman selects.
## This module inspects the selected image and returns its startup configuration,
## platform, and immutable binding.

import std/[options, sets, strutils]
import ".."/[
  types,
  utils/json,
]
import "../docker"/ids
import "./binding"
import "./chalk_platform"
import "./run"
import "./types" as podman_types

type
  InspectedBaseImage* = object
    entrypoint*:  JsonNode
    cmd*:         JsonNode
    platform*:    DeclaredPlatform
    imageId*:     string
    digest*:      string
    repoDigests*: seq[string]
    binding*:     BaseBinding

  ImageLookupKind = enum
    ilkFound,
    ilkAbsent,
    ilkFailed,
    ilkCancelled

  ImageLookupResult = object
    case kind: ImageLookupKind
    of ilkFound:
      image: InspectedBaseImage
    of ilkCancelled:
      cancellation: podman_types.ChildResult
    of ilkAbsent, ilkFailed:
      discard

proc isRegistryDigest(value: string): bool =
  return value.startsWith("sha256:") and
         validConfigId(value["sha256:".len .. ^1])

proc asNonEmptyArray(node: JsonNode): JsonNode =
  if node == nil or node.kind != JArray or len(node) == 0:
    return nil
  return node

proc parseInspectedBaseImage*(raw: string): Option[InspectedBaseImage] =
  ## Parse the output of `podman image inspect --format json`.
  ## Os and Architecture live on the image object, not inside Config.
  try:
    let parsed = parseJson(raw)
    if parsed.kind != JArray or len(parsed) == 0:
      return none(InspectedBaseImage)
    let img = parsed[0]
    if img == nil or img.kind != JObject:
      return none(InspectedBaseImage)
    let imageId = img{"Id"}.getStr()
    if not validConfigId(imageId):
      return none(InspectedBaseImage)
    let config = img{"Config"}
    var
      entrypoint: JsonNode = nil
      cmd: JsonNode = nil
      repoDigests: seq[string]
    if config != nil and config.kind == JObject:
      entrypoint = asNonEmptyArray(config{"Entrypoint"})
      cmd = asNonEmptyArray(config{"Cmd"})
    let rawRepoDigests = img{"RepoDigests"}
    if rawRepoDigests != nil and rawRepoDigests.kind == JArray:
      for item in rawRepoDigests:
        if item.kind == JString:
          repoDigests.add(item.getStr())
    let
      os = img{"Os"}.getStr()
      architecture = img{"Architecture"}.getStr()
      variant = img{"Variant"}.getStr()
      platform =
        if os == "" or architecture == "":
          DeclaredPlatform(kind: dpkUnresolved)
        else:
          parseDeclaredPlatform(
            os & "/" & architecture &
            (if variant == "": "" else: "/" & variant),
          )
    return some(InspectedBaseImage(
      entrypoint:  entrypoint,
      cmd:         cmd,
      platform:    platform,
      imageId:     imageId,
      digest:      img{"Digest"}.getStr(),
      repoDigests: repoDigests,
      binding:     BaseBinding(kind: bbConfigId, configId: imageId),
    ))
  except:
    return none(InspectedBaseImage)

proc lastNonEmptyLine(raw: string): string =
  for line in raw.splitLines():
    if line.strip() != "":
      result = line

proc redundantTaglessDigest(image: string): string =
  try:
    let parsed = parseImage(image, defaultTag = "")
    if parsed.tag != "" and
        isRegistryDigest("sha256:" & parsed.digest):
      return parsed.asRepoDigest()
  except:
    discard
  return ""

proc isAbsentImageResult(image: string,
                         r: tuple[child: podman_types.ChildResult,
                                  stdout: string, stderr: string]): bool =
  if r.child.kind != podman_types.ceExited or r.child.exitCode != 125:
    return false
  try:
    let parsed = parseJson(r.stdout)
    if parsed.kind != JArray or len(parsed) != 0:
      return false
  except:
    return false
  let diagnostic = r.stderr.lastNonEmptyLine()
  if diagnostic == "Error: " & image & ": image not known":
    return true
  let tagless = image.redundantTaglessDigest()
  return tagless != "" and
         diagnostic == "Error: " & tagless & ": image not known"

proc lookupImage(exe, image: string, expectedId: string): ImageLookupResult =
  let r = runCaptured(exe, @["image", "inspect", image, "--format", "json"])
  if isCancellation(r.child):
    return ImageLookupResult(kind: ilkCancelled, cancellation: r.child)
  if r.child.kind != podman_types.ceExited or r.child.exitCode != 0:
    if isAbsentImageResult(image, r):
      return ImageLookupResult(kind: ilkAbsent)
    return ImageLookupResult(kind: ilkFailed)
  let inspected = parseInspectedBaseImage(r.stdout)
  if inspected.isNone() or
      (expectedId != "" and inspected.get().imageId != expectedId):
    return ImageLookupResult(kind: ilkFailed)
  return ImageLookupResult(kind: ilkFound, image: inspected.get())

proc inspectImage(exe, image: string, expectedId: string,
                  cancellation: var Option[podman_types.ChildResult]):
                 Option[InspectedBaseImage] =
  let lookup = lookupImage(exe, image, expectedId)
  case lookup.kind
  of ilkFound:
    return some(lookup.image)
  of ilkCancelled:
    cancellation = some(lookup.cancellation)
  of ilkAbsent, ilkFailed:
    discard
  return none(InspectedBaseImage)

proc pullImage(exe, image: string, policy: podman_types.BasePullPolicy,
               platform: string,
               cancellation: var Option[podman_types.ChildResult]):
              Option[string] =
  var args = @["pull", "--quiet"]
  case policy
  of podman_types.bppMissing:
    discard
  of podman_types.bppNever:
    return none(string)
  of podman_types.bppAlways:
    args.add(["--policy", "always"])
  of podman_types.bppNewer:
    args.add(["--policy", "newer"])
  if platform != "":
    args.add(["--platform", platform])
  args.add(image)
  let r = runCaptured(exe, args)
  if isCancellation(r.child):
    cancellation = some(r.child)
    return none(string)
  if r.child.kind != podman_types.ceExited or r.child.exitCode != 0:
    return none(string)
  var imageId = r.stdout
  if imageId.endsWith("\r\n"):
    imageId.setLen(len(imageId) - 2)
  elif imageId.endsWith("\n"):
    imageId.setLen(len(imageId) - 1)
  if '\r' in imageId or '\n' in imageId or not validConfigId(imageId):
    return none(string)
  return some(imageId)

proc inspectPulled(exe, pulledId: string,
                   cancellation: var Option[podman_types.ChildResult]):
                  Option[InspectedBaseImage] =
  if not validConfigId(pulledId):
    return none(InspectedBaseImage)
  return inspectImage(exe, pulledId, pulledId, cancellation)

proc effectivePullPlatform(commandPlatform: Option[ChalkPlatform],
                           rootPlatform: DeclaredPlatform,
                           effectiveStageCount: int, target: ChalkPlatform): string =
  if commandPlatform.isSome():
    return $commandPlatform.get()
  if rootPlatform.kind == dpkKnown:
    return $rootPlatform.platform
  if effectiveStageCount > 1:
    return $target
  return ""

proc splitRepoDigest(value: string): tuple[repository, digest: string] =
  let marker = value.rfind("@sha256:")
  if marker <= 0 or value.find('@') != marker:
    return
  let digest = value[marker + 1 .. ^1]
  if not isRegistryDigest(digest):
    return
  result = (value[0 ..< marker], digest)

proc registryBindingReference(image: string,
                              inspected: InspectedBaseImage): Option[string] =
  if not isRegistryDigest(inspected.digest):
    return none(string)
  let source = parseImage(image, defaultTag = "")
  if source.repo == "":
    return none(string)
  let
    fullyQualified = source.isFullyQualified()
    canonicalSource = source.canonicalRepository()
  var
    seen = initHashSet[string]()
    candidateRepository = ""
  for repoDigest in inspected.repoDigests:
    let parsed = splitRepoDigest(repoDigest)
    if parsed.repository == "" or parsed.digest != inspected.digest:
      continue
    let candidate = parseImage(parsed.repository, defaultTag = "")
    if candidate.repo == "":
      continue
    let canonicalCandidate = candidate.canonicalRepository()
    if fullyQualified and canonicalCandidate != canonicalSource:
      continue
    if canonicalCandidate in seen:
      continue
    seen.incl(canonicalCandidate)
    candidateRepository = parsed.repository
  if len(seen) != 1:
    return none(string)
  return some(candidateRepository & "@" & inspected.digest)

proc fetchBaseImage*(exe, image: string,
                     cancellation: var Option[podman_types.ChildResult],
                     target: ChalkPlatform,
                     policy = podman_types.bppMissing,
                     commandPlatform = none(ChalkPlatform),
                     rootPlatform = DeclaredPlatform(kind: dpkAbsent),
                     effectiveStageCount = 1):
                    Option[InspectedBaseImage] =
  ## Selects and inspects a base image according to the pull policy and effective
  ## platform. Returns its startup configuration, platform, and immutable binding.
  ##
  ## `none()` means that the caller must not wrap the build.
  if validConfigId(image):
    if policy == podman_types.bppAlways:
      return none(InspectedBaseImage)
    return inspectImage(exe, image, image, cancellation)

  let pullPlatform = effectivePullPlatform(
    commandPlatform,
    rootPlatform,
    effectiveStageCount,
    target,
  )

  case policy
  of podman_types.bppNever:
    result = inspectImage(exe, image, "", cancellation)
    if cancellation.isSome():
      return none(InspectedBaseImage)
    return result
  of podman_types.bppAlways:
    let pulled = pullImage(exe, image, policy, pullPlatform, cancellation)
    if cancellation.isSome() or pulled.isNone():
      return none(InspectedBaseImage)
    result = inspectPulled(exe, pulled.get(), cancellation)
    if cancellation.isSome() or result.isNone():
      return none(InspectedBaseImage)
    let reference = registryBindingReference(image, result.get())
    if reference.isNone():
      return none(InspectedBaseImage)
    let proofId = pullImage(
      exe,
      reference.get(),
      podman_types.bppAlways,
      $target,
      cancellation,
    )
    if cancellation.isSome() or proofId.isNone() or
        proofId.get() != result.get().imageId:
      return none(InspectedBaseImage)
    result.get().binding = BaseBinding(
      kind:          bbRegistryDigest,
      reference:     reference.get(),
      imageId:       result.get().imageId,
      proofPlatform: target,
    )
    return result
  of podman_types.bppNewer:
    let pulled = pullImage(exe, image, policy, pullPlatform, cancellation)
    if cancellation.isSome() or pulled.isNone():
      return none(InspectedBaseImage)
    return inspectPulled(exe, pulled.get(), cancellation)
  of podman_types.bppMissing:
    let lookup = lookupImage(exe, image, "")
    case lookup.kind
    of ilkFound:
      return some(lookup.image)
    of ilkFailed:
      return none(InspectedBaseImage)
    of ilkCancelled:
      cancellation = some(lookup.cancellation)
      return none(InspectedBaseImage)
    of ilkAbsent:
      discard
    let pulled = pullImage(exe, image, policy, pullPlatform, cancellation)
    if cancellation.isSome() or pulled.isNone():
      return none(InspectedBaseImage)
    return inspectPulled(exe, pulled.get(), cancellation)
