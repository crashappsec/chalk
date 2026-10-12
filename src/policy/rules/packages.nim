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
]
import "../.."/[
  types,
]
import ".."/[
  api,
  configuration,
  helpers,
  sbom,
]

type
  PackageEntry* = tuple
    kind:  string
    value: string

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
  # https://github.com/anchore/syft/blob/main/syft/pkg/language.go
  syftLanguages* = ["c++", "dart", "dotnet", "elixir", "erlang", "go", "haskell",
                    "java", "javascript", "lua", "ocaml", "perl", "php", "python",
                    "r", "ruby", "rust", "swift", "swipl"]
  languageAliases = [
    ("golang", "go"),
    ("node", "javascript"), ("nodejs", "javascript"), ("node.js", "javascript"),
    ("js", "javascript"), ("typescript", "javascript"), ("ts", "javascript"),
    ("csharp", "dotnet"), ("c#", "dotnet"), (".net", "dotnet"),
    ("fsharp", "dotnet"), ("f#", "dotnet"), ("nuget", "dotnet"),
    ("py", "python"), ("python3", "python"),
    ("rb", "ruby"),
    ("rs", "rust"),
    # sbom.nim derives `cpp` from conan purls where syft reports `c++`
    ("cpp", "c++"), ("cxx", "c++"),
  ]
  # purl types syft maps to a language that SBOMs without syft's language
  # property leave unset, see sbom.nim
  extraPurlLanguages = [
    ("cocoapods", "swift"),
    ("cpan",      "perl"),
    ("luarocks",  "lua"),
    ("opam",      "ocaml"),
  ]
  # OS, CI and container packages, which are not dependencies in any language
  nonLanguagePurlTypes = ["alpm", "apk", "bitnami", "deb", "docker", "github",
                          "githubactions", "oci", "qpkg", "rpm"]

proc canonicalLanguage(name: string): string =
  result = name.strip().toLowerAscii()
  for (alias, language) in languageAliases:
    if alias == result:
      return language

proc normalizeLanguage*(name: string): string =
  ## The syft language for `name` or one of its aliases (`golang`, `node`,
  ## `csharp`, ...). Raises `ValueError` for other names.
  result = canonicalLanguage(name)
  if result notin syftLanguages:
    raise newException(ValueError, "unknown language " & escapeJson(name) &
                                   " (supported: " & syftLanguages.join(", ") & ")")

proc normalizeLanguages(names: seq[string], field: string): seq[string] =
  for name in names:
    try:
      let language = normalizeLanguage(name)
      if language notin result:
        result.add(language)
    except ValueError:
      raise newException(ValueError, "policy.packages." & field & ": " & getCurrentExceptionMsg())

proc parsePackagePattern*(value: string): PurlPattern =
  ## `parsePurlPattern`, also rejecting version ranges of other syntaxes
  ## (`^1.2`, `~1.2`, `1.x`, `[1.0,2.0)`, `1 - 2`, `1 || 2`) and version
  ## lists (`1.2,1.3`), which would otherwise be taken as globs matching no
  ## version, so a denied entry would silently never match.
  result = parsePurlPattern(value)
  let version = value.purlParts(pattern = true).version.strip()
  if version == "" or version[0] in {'<', '>', '=', '!'}:
    return
  var unsupported = version[0] in {'^', '~', '[', '('} or "||" in version
  for c in version:
    if c in Whitespace or c == ',':
      unsupported = true
  for part in version.split('.'):
    if part in ["x", "X"]:
      unsupported = true
  if unsupported:
    raise newException(ValueError, "unsupported version range " & escapeJson(version) &
                                   ": use a glob (`1.*`) or comparisons (`>=1.2,<2`)")

proc validateEntries(entries: seq[PackageEntry], field: string) =
  for (kind, value) in entries:
    if kind != "purl":
      raise newException(ValueError, "policy.packages." & field & ": unsupported entry kind " &
                                     escapeJson(kind) & " (supported: purl)")
    try:
      discard parsePackagePattern(value)
    except ValueError:
      raise newException(ValueError, "policy.packages." & field & ": invalid entry " &
                                     escapeJson(value) & ": " & getCurrentExceptionMsg())

type
  Patterns = object
    patterns: seq[PurlPattern]
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

proc withMessage(reason, message: string): string =
  if message == "": reason else: reason & ". " & message

type
  LanguageViolation = object
    language: string
    reason:   string
    location: string
    packages: seq[string]

proc addLanguage(violations: var seq[LanguageViolation], language, reason, id: string,
                 pkg: SbomPackage) =
  for v in violations.mitems():
    if v.language == language:
      if id notin v.packages:
        v.packages.add(id)
      return
  violations.add(LanguageViolation(language: language, reason: reason,
                                   location: pkg.location, packages: @[id]))

proc examples(packages: seq[string]): string =
  result = if len(packages) == 1: "1 package" else: $len(packages) & " packages"
  result &= ": " & packages[0 ..< min(len(packages), maxLanguageExamples)].join(", ")
  if len(packages) > maxLanguageExamples:
    result &= ", +" & $(len(packages) - maxLanguageExamples) & " more"

proc languageFinding(v: LanguageViolation, message: string): PolicyFinding =
  newSubjectFinding(ruleName, "violation", v.language,
                    withMessage(v.reason & " (" & v.packages.examples() & ")", message),
                    location = v.location)

proc languageOf(pkg: SbomPackage): string =
  ## empty when unknown
  if pkg.language != "":
    return canonicalLanguage(pkg.language)
  for (purlType, language) in extraPurlLanguages:
    if purlType == pkg.purlType:
      return language

proc packageId(pkg: SbomPackage): string =
  if pkg.purl != "":
    return pkg.purl
  result = if pkg.name != "": pkg.name else: "unnamed package"
  if pkg.version != "":
    result &= "@" & pkg.version
  if pkg.location != "":
    result &= " (" & pkg.location & ")"

proc languagesOrErrors(names: seq[string], errors: var seq[PolicyFinding]): seq[string] =
  for name in names:
    try:
      result.add(normalizeLanguage(name))
    except ValueError:
      errors.add(newSubjectFinding(ruleName, "error", "", getCurrentExceptionMsg()))

proc checkPackages*(settings: PackagesConfig, sboms: PolicySboms): seq[PolicyFinding] =
  let
    denied  = settings.denied.compile("denied")
    allowed = settings.allowed.compile("allowed")
  for e in denied.errors & allowed.errors:
    result.add(newSubjectFinding(ruleName, "error", "", e))
  result.add(sboms.errors)
  let
    allowedLanguages = settings.allowedLanguages.languagesOrErrors(result)
    deniedLanguages  = settings.deniedLanguages.languagesOrErrors(result)
  var
    languages: seq[LanguageViolation]
    seen       = initHashSet[string]()
    packages:  seq[PolicyFinding]
    # allowlists cannot vouch for packages they cannot identify, so these
    # are errors rather than passes
    noPurl, noLanguage: seq[string]

  for sbom in sboms.sboms:
    for pkg in sbom.packages:
      let id = pkg.packageId()
      if seen.containsOrIncl(id):
        continue
      let language = pkg.languageOf()
      var
        finding: PolicyFinding
        languageViolation = false
      let (deniedMatch, deniedReason) = denied.patterns.firstMatch(pkg.purl)
      if deniedMatch == pmMatch:
        finding = newSubjectFinding(ruleName, "violation", pkg.purl,
          withMessage("package is denied (" & deniedReason & ")", settings.message),
          location = pkg.location)
      elif deniedMatch == pmUnknown:
        finding = newSubjectFinding(ruleName, "error", pkg.purl, deniedReason,
                                    location = pkg.location)
      if language != "" and language in deniedLanguages:
        languages.addLanguage(language, "language is denied", id, pkg)
        languageViolation = true
      elif len(allowedLanguages) > 0:
        if language != "" and language notin allowedLanguages:
          languages.addLanguage(language, "language is not allowed", id, pkg)
          languageViolation = true
        elif language == "" and pkg.purlType notin nonLanguagePurlTypes:
          noLanguage.add(id)
      # a denied range that cannot be decided must not hide an allowlist
      # violation, which would then only be an error that on_error can allow
      if not languageViolation and deniedMatch != pmMatch and len(allowed.patterns) > 0:
        if pkg.purl == "":
          noPurl.add(id)
        else:
          let (allowedMatch, allowedReason) = allowed.patterns.firstMatch(pkg.purl)
          if allowedMatch == pmNoMatch:
            finding = newSubjectFinding(ruleName, "violation", pkg.purl,
              withMessage("package is not in the list of allowed packages", settings.message),
              location = pkg.location)
          elif allowedMatch == pmUnknown and finding.kind == "":
            finding = newSubjectFinding(ruleName, "error", pkg.purl, allowedReason,
                                        location = pkg.location)
      if finding.kind != "":
        packages.add(finding)

  for v in languages:
    result.add(v.languageFinding(settings.message))
  if len(noLanguage) > 0:
    result.add(newSubjectFinding(ruleName, "error", "",
      "could not determine the language of " & noLanguage.examples() &
      ", so allowed_languages cannot be checked for them"))
  if len(noPurl) > 0:
    result.add(newSubjectFinding(ruleName, "error", "",
      "could not determine the package URL of " & noPurl.examples() &
      ", so allowed packages cannot be checked for them"))
  result.add(packages.capFindings(ruleName, maxPackageFindings, "packages"))

proc hasChecks*(settings: PackagesConfig): bool =
  len(settings.denied) > 0 or len(settings.allowed) > 0 or
    len(settings.allowedLanguages) > 0 or len(settings.deniedLanguages) > 0

proc loadPackagesConfig*(): Option[PackagesConfig] =
  ## Raises `ValueError` for unknown languages, entry kinds or invalid
  ## patterns, which the engine reports as a configuration error.
  if not policyBoolSetting([ruleName, "enabled"], false):
    return none(PackagesConfig)
  var settings = PackagesConfig(
    allowedLanguages: policyStringsSetting([ruleName, "allowed_languages"])
                        .normalizeLanguages("allowed_languages"),
    deniedLanguages:  policyStringsSetting([ruleName, "denied_languages"])
                        .normalizeLanguages("denied_languages"),
    message:          policyStringSetting([ruleName, "message"], ""),
  )
  for (kind, value) in policyPairsSetting([ruleName, "denied"]):
    settings.denied.add((kind, value))
  for (kind, value) in policyPairsSetting([ruleName, "allowed"]):
    settings.allowed.add((kind, value))
  settings.denied.validateEntries("denied")
  settings.allowed.validateEntries("allowed")
  return some(settings)

proc validateStrings(node: JsonNode, path: string): seq[string] =
  for entry in node.getElems():
    if entry.kind != JString:
      raise newException(ValueError, path & " entries must be strings")
    result.add(entry.getStr())

proc validateEntries(node: JsonNode, path, field: string) =
  node.validatePairs(path & field)
  var entries: seq[PackageEntry]
  for entry in node.getElems():
    entries.add((entry[0].getStr(), entry[1].getStr()))
  entries.validateEntries(field)

proc validatePackagesJson(node: JsonNode, path: string) =
  node.validateFields(packagesJsonFields, path)
  node{"denied"}.validateEntries(path, "denied")
  node{"allowed"}.validateEntries(path, "allowed")
  discard node{"allowed_languages"}.validateStrings(path & "allowed_languages")
    .normalizeLanguages("allowed_languages")
  discard node{"denied_languages"}.validateStrings(path & "denied_languages")
    .normalizeLanguages("denied_languages")

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
  loaded.checkPackages(input.policySboms(ruleName))

proc packagesHint(): PolicyHint =
  # without a message the step summary would suggest using an allowed image
  if loaded.message == "":
    return PolicyHint()
  result = PolicyHint(rule: ruleName, message: loaded.message)
  for lang in loaded.allowedLanguages:
    result.allowed.add(lang)
  for entry in loaded.allowed:
    result.allowed.add(entry.value)

proc loadPackagesRule*() =
  # SBOMs are produced per build context directory, which the engine only
  # collects for rules that require it
  newPolicyInputRule(ruleName, loadPackages, checkPackagesInput,
                     requiresContext = true, hint = packagesHint)
