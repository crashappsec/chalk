##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.registries`: restrict the registries a build pulls images from
## and the registries `docker build --push` and `docker push` push to.
## Registry-level, unlike `golden_images` which allowlists exact images.
## See docs/design-build-policy.md for the matching semantics.

import std/[
  json,
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
import ./golden_images

type
  RegistryEntry* = tuple
    kind:  string
    value: string

  RegistriesConfig* = object
    pullAllowed*:   seq[RegistryEntry]
    pullDenied*:    seq[RegistryEntry]
    pushAllowed*:   seq[RegistryEntry]
    pushDenied*:    seq[RegistryEntry]
    requireDigest*: bool
    message*:       string

const
  ruleName  = "registries"
  dockerHub = "registry-1.docker.io" # as normalized by docker/ids

proc hasGlob(value: string): bool =
  '*' in value or '?' in value

proc looksLikeHost(part: string): bool =
  ## docker's rule for the first path component of a reference, see
  ## https://github.com/distribution/reference/blob/8c942b0459dfdcc5b6685581dd0a5a470f615bff/normalize.go#L143-L191
  ## plus glob characters, which only make sense in a host pattern here
  part.toLowerAscii() == "localhost" or
    part.contains({'.', ':'}) or
    part != part.toLowerAscii() or
    part.hasGlob()

proc normalizeHost(host: string): string =
  let lower = host.toLowerAscii()
  if lower.hasGlob() or not lower.looksLikeHost():
    return lower
  # maps docker.io and index.docker.io to the registry docker pulls from
  return parseImage(lower & "/x").registry

proc normalizeRegistryPattern*(pattern: string): string =
  ## `host` or `host/repository` glob, matched against the normalized
  ## `registry/repository` of an image. Tags and digests are ignored.
  let value = pattern.strip().split('@')[0]
  let slash = value.find('/')
  if slash < 0:
    return normalizeHost(value)
  var
    host = value[0 ..< slash]
    path = value[slash + 1 .. ^1]
  if host.looksLikeHost():
    host = normalizeHost(host)
  else:
    # `acme/*` is a Docker Hub namespace, as `docker pull acme/app` is
    host = dockerHub
    path = value
  let colon = path.rfind(':')
  if colon >= 0:
    path = path[0 ..< colon]
  if host == dockerHub and '/' notin path and not path.hasGlob():
    path = "library/" & path
  return host & "/" & path

proc registryRef*(image: DockerImage): tuple[host, repo: string] =
  ## lowercase registry host and `host/repository` the image is pulled from
  ## or pushed to
  if image.repo == "":
    return ("", "")
  let
    normalized = image.normalize().repo
    slash      = normalized.find('/')
  if slash < 0:
    return ("", "")
  let host = normalized[0 ..< slash].toLowerAscii()
  return (host, host & normalized[slash .. ^1])

proc familiarRegistry(value: string): string =
  if value == dockerHub or value.startsWith(dockerHub & "/"):
    return "docker.io" & value[len(dockerHub) .. ^1]
  return value

proc matchesRegistry*(image: DockerImage, pattern: string): bool =
  let
    (host, repo) = image.registryRef()
    normalized   = normalizeRegistryPattern(pattern)
  if host == "":
    return false
  if '/' notin normalized:
    return globMatch(normalized, host)
  return globMatch(normalized, repo)

proc checkRegistry*(image:   DockerImage,
                    allowed: seq[RegistryEntry],
                    denied:  seq[RegistryEntry],
                    action:  string, # "pull" or "push"
                    ): tuple[result: MatchResult, reason: string] =
  ## Denied entries win over allowed ones. An empty `allowed` list allows
  ## every registry that is not denied.
  let repo = image.registryRef().repo
  if repo == "":
    return (mrUnknown, "cannot determine the registry of the image")
  var unknownKinds: seq[string]
  for entry in denied:
    case entry.kind
    of "glob":
      if image.matchesRegistry(entry.value):
        return (mrDenied, familiarRegistry(repo) & " is in a registry denied for " &
                          action & " (" & entry.value & ")")
    else:
      if entry.kind notin unknownKinds:
        unknownKinds.add(entry.kind)
  # an unknown kind in the denylist could have denied the image
  if len(unknownKinds) > 0:
    return (mrUnknown, "unsupported registry entry kind(s) in " & action & "_denied: " &
                       unknownKinds.join(", "))
  if len(allowed) == 0:
    return (mrAllowed, "")
  for entry in allowed:
    case entry.kind
    of "glob":
      if image.matchesRegistry(entry.value):
        return (mrAllowed, "")
    else:
      if entry.kind notin unknownKinds:
        unknownKinds.add(entry.kind)
  if len(unknownKinds) > 0:
    return (mrUnknown, "unsupported registry entry kind(s) in " & action & "_allowed: " &
                       unknownKinds.join(", "))
  return (mrDenied, familiarRegistry(repo) & " is not in a registry allowed for " & action)

proc checksPull*(settings: RegistriesConfig): bool =
  len(settings.pullAllowed) > 0 or len(settings.pullDenied) > 0 or settings.requireDigest

proc checksPush*(settings: RegistriesConfig): bool =
  len(settings.pushAllowed) > 0 or len(settings.pushDenied) > 0

proc withMessage(settings: RegistriesConfig, reason: string): string =
  if settings.message == "":
    return reason
  return reason & ". " & settings.message

proc pushFinding(target, kind, reason: string): PolicyFinding =
  PolicyFinding(rule: ruleName, kind: kind, image: target, source: "push", reason: reason)

proc check*(settings: RegistriesConfig, input: PolicyInput): seq[PolicyFinding] =
  if settings.checksPull():
    for subject in input.subjects:
      if subject.image.repo == "scratch":
        continue
      let (res, reason) = subject.image.checkRegistry(settings.pullAllowed,
                                                      settings.pullDenied, "pull")
      case res
      of mrAllowed:
        discard
      of mrDenied:
        result.add(subject.newFinding(ruleName, "violation", settings.withMessage(reason)))
        continue
      of mrUnknown:
        result.add(subject.newFinding(ruleName, "error", reason))
        continue
      # the reference as written: a digest chalk resolved for a tag
      # does not pin what a later build pulls
      if settings.requireDigest and subject.image.digest == "":
        result.add(subject.newFinding(ruleName, "violation",
                                      settings.withMessage("image is not pinned by digest")))

  if not settings.checksPush():
    return
  if input.command == "":
    # collection failed before push targets were known; when pull checks are
    # on the engine already reports these errors against this rule
    if not settings.checksPull():
      for e in input.errors:
        var f = e
        f.rule = ruleName
        result.add(f)
      if len(input.errors) == 0:
        result.add(pushFinding("", "error", "could not determine push targets"))
    return
  for target in input.pushTargets:
    let (res, reason) = parseImage(target, defaultTag = "").checkRegistry(
      settings.pushAllowed, settings.pushDenied, "push")
    case res
    of mrAllowed:
      discard
    of mrDenied:
      result.add(pushFinding(target, "violation", settings.withMessage(reason)))
    of mrUnknown:
      result.add(pushFinding(target, "error", reason))

proc entries(path: string): seq[RegistryEntry] =
  for (kind, value) in policyPairsSetting([ruleName, path]):
    result.add((kind, value))

proc loadRegistriesConfig*(): Option[RegistriesConfig] =
  if not policyBoolSetting([ruleName, "enabled"], false):
    return none(RegistriesConfig)
  return some(RegistriesConfig(
    pullAllowed:   entries("pull_allowed"),
    pullDenied:    entries("pull_denied"),
    pushAllowed:   entries("push_allowed"),
    pushDenied:    entries("push_denied"),
    requireDigest: policyBoolSetting([ruleName, "require_digest"], false),
    message:       policyStringSetting([ruleName, "message"], ""),
  ))

const registriesJsonFields = [
  PolicyJsonField(name: "enabled",        kind: JBool),
  PolicyJsonField(name: "pull_allowed",   kind: JArray),
  PolicyJsonField(name: "pull_denied",    kind: JArray),
  PolicyJsonField(name: "push_allowed",   kind: JArray),
  PolicyJsonField(name: "push_denied",    kind: JArray),
  PolicyJsonField(name: "require_digest", kind: JBool),
  PolicyJsonField(name: "message",        kind: JString),
]

proc validateRegistriesJson*(node: JsonNode, path: string) =
  node.validateFields(registriesJsonFields, path)
  for list in ["pull_allowed", "pull_denied", "push_allowed", "push_denied"]:
    node{list}.validatePairs(path & list)

registerPolicyJsonSection(ruleName, validateRegistriesJson)

var
  loaded: RegistriesConfig
  rule:   PolicyRule

proc loadRegistries(): bool =
  let settings = loadRegistriesConfig()
  if settings.isNone():
    return false
  loaded = settings.get()
  # an incomplete list of pulled images could let a denied registry through,
  # while a push-only policy does not need to know the pulled images
  rule.requiresAllSubjects = loaded.checksPull()
  return true

proc checkRegistries(input: PolicyInput): seq[PolicyFinding] =
  loaded.check(input)

proc registriesHint(): PolicyHint =
  result = PolicyHint(rule: ruleName, message: loaded.message)
  for entry in loaded.pullAllowed:
    result.allowed.add(entry.value)
  for entry in loaded.pushAllowed:
    result.allowed.add("push: " & entry.value)

proc loadRegistriesRule*() =
  newPolicyInputRule(ruleName, loadRegistries, checkRegistries,
                     requiresAllSubjects = true, hint = registriesHint)
  for registered in policyRules():
    if registered.name == ruleName:
      rule = registered
