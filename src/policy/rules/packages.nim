##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.packages`: restrict the languages and packages a build depends on,
## as listed by the SBOM of its build context (see policy/sbom.nim and
## docs/design-build-policy.md).

import std/[
  json,
  sets,
  strutils,
  uri,
]
import "../.."/[
  types,
  utils/semver,
]
import ".."/[
  api,
  configuration,
  sbom,
]
import ./golden_images

type
  PackageEntry* = tuple
    kind:  string
    value: string

  VersionConstraint = tuple
    op:      string
    version: Version

  PackagePattern* = object
    raw:         string
    name:        string # `type/namespace/name` glob, see `purlParts`
    versionGlob: string # empty: any version
    constraints: seq[VersionConstraint]

  PackageMatch* = enum
    pmMatch, pmNoMatch, pmUnknown

  PackagesConfig* = object
    denied*:           seq[PackageEntry]
    allowed*:          seq[PackageEntry]
    allowedLanguages*: seq[string]
    deniedLanguages*:  seq[string]
    message*:          string

const
  ruleName             = "packages"
  maxPackageFindings*  = 200
  maxLanguageExamples  = 3
  packagesJsonFields = [
    PolicyJsonField(name: "enabled",           kind: JBool),
    PolicyJsonField(name: "denied",            kind: JArray),
    PolicyJsonField(name: "allowed",           kind: JArray),
    PolicyJsonField(name: "allowed_languages", kind: JArray),
    PolicyJsonField(name: "denied_languages",  kind: JArray),
    PolicyJsonField(name: "message",           kind: JString),
  ]

proc normalizePypiName(name: string): string =
  # https://packaging.python.org/en/latest/specifications/name-normalization/
  var lastSep = false
  for c in name:
    if c in {'-', '_', '.'}:
      if not lastSep:
        result.add('-')
      lastSep = true
    else:
      result.add(c)
      lastSep = false

proc purlParts*(purl: string): tuple[name, version: string] =
  ## `pkg:type/namespace/name@version?qualifiers#subpath` as a lowercase,
  ## percent-decoded `type/namespace/name` and the decoded version.
  ## https://github.com/package-url/purl-spec/blob/main/PURL-SPECIFICATION.rst
  var s = purl.strip()
  if s.toLowerAscii().startsWith("pkg:"):
    s = s[4 .. ^1]
  s = s.strip(trailing = false, chars = {'/'})
  let hash = s.find('#')
  if hash >= 0:
    s = s[0 ..< hash]
  let query = s.find('?')
  if query >= 0:
    s = s[0 ..< query]
  # the version follows the last `@` that does not start a path segment, so
  # npm scopes written unencoded (`pkg:npm/@angular/core`) are not versions
  var at = -1
  for i in countdown(len(s) - 1, 1):
    if s[i] == '@' and s[i - 1] != '/':
      at = i
      break
  var name = if at >= 0: s[0 ..< at] else: s
  if at >= 0:
    result.version = decodeUrl(s[at + 1 .. ^1], decodePlus = false)
  name = decodeUrl(name, decodePlus = false).toLowerAscii()
  let slash = name.find('/')
  if slash > 0 and name[0 ..< slash] == "pypi":
    let last = name.rfind('/')
    name = name[0 .. last] & normalizePypiName(name[last + 1 .. ^1])
  result.name = name

proc normalizeVersion(version: string): string =
  # go module versions carry a `v` prefix other ecosystems do not
  result = version.toLowerAscii()
  if len(result) > 1 and result[0] == 'v' and result[1] in Digits:
    result = result[1 .. ^1]

proc parsePackagePattern*(value: string): PackagePattern =
  ## Raises `ValueError` for a pattern that is not a purl or has an invalid
  ## version range.
  if not value.strip().toLowerAscii().startsWith("pkg:"):
    raise newException(ValueError, "must start with pkg:")
  let (name, version) = value.purlParts()
  if '/' notin name or name.startsWith("/") or name.endsWith("/"):
    raise newException(ValueError, "must be pkg:<type>/<name>")
  result = PackagePattern(raw: value, name: name)
  let spec = version.strip()
  if spec == "" or spec[0] notin {'<', '>', '=', '!'}:
    result.versionGlob = spec
    return
  for part in spec.split(','):
    let constraint = part.strip()
    var i = 0
    while i < len(constraint) and constraint[i] in {'<', '>', '=', '!'}:
      inc(i)
    var op = constraint[0 ..< i]
    if op == "==":
      op = "="
    if op notin ["<", "<=", ">", ">=", "=", "!="]:
      raise newException(ValueError, "invalid version operator " & escapeJson(op))
    try:
      result.constraints.add((op, parseVersion(constraint[i .. ^1].strip())))
    except CatchableError:
      raise newException(ValueError, "invalid version " & escapeJson(constraint[i .. ^1]) &
                                     " (ranges support MAJOR[.MINOR[.PATCH]][-suffix])")

proc satisfies(version: Version, constraint: VersionConstraint): bool =
  case constraint.op
  of "<":  version < constraint.version
  of "<=": version <= constraint.version
  of ">":  version > constraint.version
  of ">=": version >= constraint.version
  of "!=": version != constraint.version
  else:    version == constraint.version

proc matches*(pattern: PackagePattern, purl: string): tuple[result: PackageMatch, reason: string] =
  if purl == "":
    return (pmNoMatch, "")
  let (name, version) = purl.purlParts()
  if not globMatch(pattern.name, name):
    return (pmNoMatch, "")
  if len(pattern.constraints) == 0:
    if pattern.versionGlob == "" or
       globMatch(pattern.versionGlob.normalizeVersion(), version.normalizeVersion()):
      return (pmMatch, "")
    return (pmNoMatch, "")
  var parsed: Version
  try:
    parsed = parseVersion(version)
  except CatchableError:
    return (pmUnknown, "version " & escapeJson(version) & " cannot be compared with " &
                       pattern.raw)
  for constraint in pattern.constraints:
    if not parsed.satisfies(constraint):
      return (pmNoMatch, "")
  return (pmMatch, "")

type
  Patterns = object
    patterns: seq[PackagePattern]
    errors:   seq[string]

proc compile(entries: seq[PackageEntry], field: string): Patterns =
  var unknownKinds: seq[string]
  for entry in entries:
    if entry.kind != "purl":
      if entry.kind notin unknownKinds:
        unknownKinds.add(entry.kind)
      continue
    try:
      result.patterns.add(parsePackagePattern(entry.value))
    except ValueError:
      result.errors.add("invalid " & field & " entry " & escapeJson(entry.value) & ": " &
                        getCurrentExceptionMsg())
  if len(unknownKinds) > 0:
    result.errors.add("unsupported " & field & " entry kind(s): " & unknownKinds.join(", "))

proc firstMatch(patterns: seq[PackagePattern], purl: string): tuple[result: PackageMatch, reason: string] =
  result = (pmNoMatch, "")
  for pattern in patterns:
    let (res, reason) = pattern.matches(purl)
    case res
    of pmMatch:
      return (pmMatch, pattern.raw)
    of pmUnknown:
      result = (pmUnknown, reason)
    of pmNoMatch:
      discard

proc withMessage(reason, message: string): string =
  if message == "": reason else: reason & ". " & message

type
  LanguageViolation = object
    language: string
    reason:   string
    location: string
    purls:    seq[string]

proc addLanguage(violations: var seq[LanguageViolation], language, reason: string,
                 pkg: SbomPackage) =
  for v in violations.mitems():
    if v.language == language:
      if pkg.purl notin v.purls:
        v.purls.add(pkg.purl)
      return
  violations.add(LanguageViolation(language: language, reason: reason,
                                   location: pkg.location, purls: @[pkg.purl]))

proc languageFinding(v: LanguageViolation, message: string): PolicyFinding =
  var examples = v.purls[0 ..< min(len(v.purls), maxLanguageExamples)].join(", ")
  if len(v.purls) > maxLanguageExamples:
    examples &= ", +" & $(len(v.purls) - maxLanguageExamples) & " more"
  let count = if len(v.purls) == 1: "1 package" else: $len(v.purls) & " packages"
  newSubjectFinding(ruleName, "violation", v.language,
                    withMessage(v.reason & " (" & count & ": " & examples & ")", message),
                    location = v.location)

proc checkPackages*(settings: PackagesConfig, sboms: PolicySboms): seq[PolicyFinding] =
  let
    denied  = settings.denied.compile("denied")
    allowed = settings.allowed.compile("allowed")
  for e in denied.errors & allowed.errors & sboms.errors:
    result.add(newSubjectFinding(ruleName, "error", "", e))
  var
    allowedLanguages, deniedLanguages: seq[string]
    languages: seq[LanguageViolation]
    seen       = initHashSet[string]()
    packages:  seq[PolicyFinding]
    dropped    = 0
  for lang in settings.allowedLanguages:
    allowedLanguages.add(lang.strip().toLowerAscii())
  for lang in settings.deniedLanguages:
    deniedLanguages.add(lang.strip().toLowerAscii())

  for sbom in sboms.sboms:
    if sbom.truncated:
      result.add(newSubjectFinding(ruleName, "error", "",
        "the SBOM of " & sbom.source & " lists more than " & $maxSbomPackages &
        " packages; only the first were checked"))
    for pkg in sbom.packages:
      # without a purl a package can be neither identified nor matched
      if pkg.purl == "" or seen.containsOrIncl(pkg.purl):
        continue
      var finding: PolicyFinding
      let (deniedMatch, deniedReason) = denied.patterns.firstMatch(pkg.purl)
      if deniedMatch == pmMatch:
        finding = newSubjectFinding(ruleName, "violation", pkg.purl,
          withMessage("package is denied (" & deniedReason & ")", settings.message),
          location = pkg.location)
      elif deniedMatch == pmUnknown:
        finding = newSubjectFinding(ruleName, "error", pkg.purl, deniedReason,
                                    location = pkg.location)
      if pkg.language != "" and pkg.language in deniedLanguages:
        languages.addLanguage(pkg.language, "language is denied", pkg)
      elif pkg.language != "" and len(allowedLanguages) > 0 and
           pkg.language notin allowedLanguages:
        languages.addLanguage(pkg.language, "language is not allowed", pkg)
      elif finding.kind == "" and len(allowed.patterns) > 0:
        let (allowedMatch, allowedReason) = allowed.patterns.firstMatch(pkg.purl)
        if allowedMatch == pmNoMatch:
          finding = newSubjectFinding(ruleName, "violation", pkg.purl,
            withMessage("package is not in the list of allowed packages", settings.message),
            location = pkg.location)
        elif allowedMatch == pmUnknown:
          finding = newSubjectFinding(ruleName, "error", pkg.purl, allowedReason,
                                      location = pkg.location)
      if finding.kind == "":
        continue
      if len(packages) >= maxPackageFindings:
        inc(dropped)
      else:
        packages.add(finding)

  for v in languages:
    result.add(v.languageFinding(settings.message))
  result.add(packages)
  if dropped > 0:
    result.add(newSubjectFinding(ruleName, "violation", "",
      $dropped & " more packages violate the policy; only the first " &
      $maxPackageFindings & " are reported"))

proc hasChecks*(settings: PackagesConfig): bool =
  len(settings.denied) > 0 or len(settings.allowed) > 0 or
    len(settings.allowedLanguages) > 0 or len(settings.deniedLanguages) > 0

proc loadPackagesConfig*(): Option[PackagesConfig] =
  if not policyBoolSetting([ruleName, "enabled"], false):
    return none(PackagesConfig)
  var settings = PackagesConfig(
    allowedLanguages: policyStringsSetting([ruleName, "allowed_languages"]),
    deniedLanguages:  policyStringsSetting([ruleName, "denied_languages"]),
    message:          policyStringSetting([ruleName, "message"], ""),
  )
  for (kind, value) in policyPairsSetting([ruleName, "denied"]):
    settings.denied.add((kind, value))
  for (kind, value) in policyPairsSetting([ruleName, "allowed"]):
    settings.allowed.add((kind, value))
  return some(settings)

proc validateStrings(node: JsonNode, path: string) =
  for entry in node.getElems():
    if entry.kind != JString:
      raise newException(ValueError, path & " entries must be strings")

proc validatePackagesJson(node: JsonNode, path: string) =
  node.validateFields(packagesJsonFields, path)
  node{"denied"}.validatePairs(path & "denied")
  node{"allowed"}.validatePairs(path & "allowed")
  node{"allowed_languages"}.validateStrings(path & "allowed_languages")
  node{"denied_languages"}.validateStrings(path & "denied_languages")

registerPolicyJsonSection(ruleName, validatePackagesJson)

var loaded: PackagesConfig

proc loadPackages(): bool =
  let settings = loadPackagesConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome()

proc checkPackagesInput(input: PolicyInput): seq[PolicyFinding] =
  # producing an SBOM can take minutes, so not without anything to check
  if not loaded.hasChecks():
    return
  loaded.checkPackages(input.policySboms())

proc packagesHint(): PolicyHint =
  result = PolicyHint(rule: ruleName, message: loaded.message)
  for lang in loaded.allowedLanguages:
    result.allowed.add(lang)
  for entry in loaded.allowed:
    result.allowed.add(entry.value)

proc loadPackagesRule*() =
  newPolicyInputRule(ruleName, loadPackages, checkPackagesInput, hint = packagesHint)
