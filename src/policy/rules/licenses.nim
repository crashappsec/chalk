##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.licenses`: report packages whose licenses are denied or not
## allowed, read from the SBOM of the build context (CycloneDX, SPDX or syft
## JSON). See docs/design-build-policy.md for the settings and semantics.

import std/[
  algorithm,
  json,
  sequtils,
  sets,
  strutils,
  tables,
]
import "../.."/[
  plugins/externalTool,
  types,
]
import ".."/[
  api,
  configuration,
]
import ./golden_images

const
  ruleName = "licenses"
  ## Small, opinionated groups of SPDX ids, see https://spdx.org/licenses/
  ## for the ids and https://blueoakcouncil.org/copyleft for the families.
  licensePresets = {
    "strong_copyleft":  @["GPL-*", "AGPL-*", "SSPL-1.0", "OSL-*", "EUPL-*", "RPL-*", "Sleepycat"],
    "weak_copyleft":    @["LGPL-*", "MPL-*", "EPL-*", "CDDL-*", "CPL-1.0", "MS-RL"],
    "network_copyleft": @["AGPL-*", "SSPL-1.0", "OSL-3.0", "RPL-*"],
  }.toTable()
  ## purl types of OS distribution packages, which come with the base image
  ## rather than with the application (https://github.com/package-url/purl-spec)
  osPackageTypes = ["apk", "alpm", "deb", "ebuild", "rpm"]
  unknownChoices = ["ignore", "violation", "error"]
  maxPackages    = 100_000
  maxFindings    = 200
  maxContextDirs = 4

type
  LicenseNodeKind* = enum
    lnLicense, lnAnd, lnOr

  LicenseNode* = ref object
    kind*:      LicenseNodeKind
    id*:        string # lnLicense: normalized SPDX id or the name as written
    exception*: string # lnLicense: `WITH` exception, empty without one
    children*:  seq[LicenseNode] # lnAnd, lnOr

  Verdict* = enum
    vAllowed, vUnknown, vDenied

  SbomPackage* = object
    name*:     string
    version*:  string
    purl*:     string
    pkgType*:  string # syft package type, when the SBOM records one
    location*: string
    licenses*: seq[string] # as written in the SBOM, each applies (AND)

  LicensesConfig* = object
    denied*:            seq[string] # lowercase, presets expanded
    allowed*:           seq[string]
    configuredAllowed*: seq[string] # as configured, for the step summary
    unknown*:           string
    exceptions*:        seq[string]
    ignoreTypes*:       seq[string]
    includeOsPackages*: bool
    message*:           string

# SPDX ids, operators and LicenseRefs are matched case-insensitively
# (https://spdx.github.io/spdx-spec/v2.3/SPDX-license-expressions/)

proc isGlob(s: string): bool =
  '*' in s or '?' in s

proc dropVersionV(s: string): string =
  ## `gplv2` -> `gpl2`
  for i, c in s:
    if c == 'v' and i > 0 and i + 1 < len(s) and s[i - 1].isAlphaAscii() and s[i + 1].isDigit():
      continue
    result.add(c)

proc compactName(name: string): string =
  result = " " & name.toLowerAscii() & " "
  for (long, short) in [("gnu lesser general public", "lgpl"),
                        ("gnu library general public", "lgpl"),
                        ("lesser general public", "lgpl"),
                        ("library general public", "lgpl"),
                        ("gnu affero general public", "agpl"),
                        ("affero general public", "agpl"),
                        ("gnu general public", "gpl"),
                        ("general public", "gpl"),
                        ("mozilla public", "mpl"),
                        ("eclipse public", "epl"),
                        ("apache software", "apache"),
                        ("or later", ""), ("or-later", ""), ("-only", ""), (" only", ""),
                        ("licenses", ""), ("license", ""), ("licence", ""),
                        ("version", ""), (" the ", " ")]:
    result = result.replace(long, short)
  var alnum = ""
  for c in result:
    if c.isAlphaNumeric():
      alnum.add(c)
  result = alnum.dropVersionV()
  # `2.0` and `2` are the same version
  if len(result) > 2 and result[^1] == '0' and result[^2].isDigit():
    result.setLen(len(result) - 1)

const
  licenseAliases = {
    "gpl1": "GPL-1.0", "gpl2": "GPL-2.0", "gpl3": "GPL-3.0",
    "gnugpl2": "GPL-2.0", "gnugpl3": "GPL-3.0",
    "lgpl2": "LGPL-2.0", "lgpl21": "LGPL-2.1", "lgpl3": "LGPL-3.0",
    "agpl1": "AGPL-1.0", "agpl3": "AGPL-3.0",
    "apache1": "Apache-1.0", "apache11": "Apache-1.1", "apache2": "Apache-2.0",
    "asl2": "Apache-2.0",
    "mit": "MIT", "mitx": "MIT", "expat": "MIT",
    "isc": "ISC",
    "bsd2clause": "BSD-2-Clause", "simplifiedbsd": "BSD-2-Clause", "freebsd": "BSD-2-Clause",
    "bsd3clause": "BSD-3-Clause", "newbsd": "BSD-3-Clause", "revisedbsd": "BSD-3-Clause",
    "modifiedbsd": "BSD-3-Clause",
    "mpl1": "MPL-1.0", "mpl11": "MPL-1.1", "mpl2": "MPL-2.0",
    "epl1": "EPL-1.0", "epl2": "EPL-2.0",
    "unlicense": "Unlicense", "cc01": "CC0-1.0", "cc0": "CC0-1.0",
    "zlib": "Zlib", "sspl1": "SSPL-1.0", "serversidepublic1": "SSPL-1.0",
  }.toTable()
  # GNU families take an -only/-or-later suffix since SPDX 3.0
  gnuFamilies = ["GPL-", "LGPL-", "AGPL-"]

proc normalizeLicense*(name: string): string =
  ## Best effort mapping of common non-SPDX names (`GPLv2`, `Apache 2.0`) and
  ## deprecated ids (`GPL-2.0+`) to SPDX ids. Anything else is kept as is.
  var name = name.strip()
  if name.toLowerAscii().startsWith("licenseref-"):
    let alias = licenseAliases.getOrDefault(compactName(name[11 .. ^1].replace("-", " ")))
    if alias == "":
      return name
    name = alias
  let
    lower   = name.toLowerAscii()
    orLater = lower.endsWith("+") or "or later" in lower or "or-later" in lower
  var alias = licenseAliases.getOrDefault(compactName(name))
  # e.g. `GNU General Public License v3 or later (GPLv3+)`
  let open = name.rfind('(')
  if alias == "" and open > 0 and name.endsWith(")"):
    alias = licenseAliases.getOrDefault(compactName(name[0 ..< open]))
    if alias == "":
      alias = licenseAliases.getOrDefault(compactName(name[open + 1 .. ^2]))
  if alias == "":
    return name
  for family in gnuFamilies:
    if alias.startsWith(family):
      return alias & (if orLater: "-or-later" else: "-only")
  return alias

proc tokenize(expression: string): seq[string] =
  var current = ""
  for c in expression:
    if c in {'(', ')'} or c in Whitespace:
      if current != "":
        result.add(current)
        current = ""
      if c in {'(', ')'}:
        result.add($c)
    else:
      current.add(c)
  if current != "":
    result.add(current)

proc isOperator(token: string): bool =
  token.toUpperAscii() in ["AND", "OR", "WITH"]

proc parseLicenseExpression*(expression: string): LicenseNode =
  ## Parses an SPDX license expression where `WITH` binds tighter than `AND`,
  ## which binds tighter than `OR`. Text that is not a valid expression (e.g.
  ## `Apache License 2.0`) is a single license name.
  let tokens = tokenize(expression)
  var pos = 0

  proc peek(): string =
    if pos < len(tokens): tokens[pos].toUpperAscii() else: ""

  proc parseOr(): LicenseNode

  proc parseTerm(): LicenseNode =
    if peek() == "(":
      inc(pos)
      result = parseOr()
      if peek() != ")":
        raise newException(ValueError, "unbalanced parentheses")
      inc(pos)
      return
    if pos >= len(tokens) or tokens[pos] == ")" or tokens[pos].isOperator():
      raise newException(ValueError, "expected a license id")
    result = LicenseNode(kind: lnLicense, id: normalizeLicense(tokens[pos]))
    inc(pos)
    if peek() == "WITH":
      inc(pos)
      if pos >= len(tokens) or tokens[pos] in ["(", ")"] or tokens[pos].isOperator():
        raise newException(ValueError, "expected a license exception")
      result.exception = tokens[pos]
      inc(pos)

  proc parseBinary(kind: LicenseNodeKind, op: string,
                   operand: proc(): LicenseNode): LicenseNode =
    result = operand()
    if peek() != op:
      return
    result = LicenseNode(kind: kind, children: @[result])
    while peek() == op:
      inc(pos)
      result.children.add(operand())

  proc parseAnd(): LicenseNode =
    parseBinary(lnAnd, "AND", parseTerm)

  proc parseOr(): LicenseNode =
    parseBinary(lnOr, "OR", parseAnd)

  try:
    if len(tokens) == 0:
      raise newException(ValueError, "empty expression")
    result = parseOr()
    if pos != len(tokens):
      raise newException(ValueError, "unexpected " & tokens[pos])
  except ValueError:
    result = LicenseNode(kind: lnLicense, id: normalizeLicense(expression))

proc isUnknownLicense(id: string): bool =
  id == "" or id.toUpperAscii() in ["NOASSERTION", "NONE", "UNKNOWN"]

proc matches(pattern: string, node: LicenseNode): bool =
  ## `pattern` is lowercase. Without `WITH` it matches the license whatever
  ## its exception, as an exception only grants additional permissions.
  if " with " in pattern:
    if node.exception == "":
      return false
    return globMatch(pattern, (node.id & " with " & node.exception).toLowerAscii())
  return globMatch(pattern, node.id.toLowerAscii())

proc licenseVerdict*(settings: LicensesConfig, node: LicenseNode,
                     offending: var seq[string]): Verdict =
  ## `offending` collects the licenses that make the expression fail
  case node.kind
  of lnLicense:
    if node.id.isUnknownLicense():
      return vUnknown
    var allowedHit, allowedWith, deniedHit = false
    for pattern in settings.allowed:
      if pattern.matches(node):
        allowedHit = true
        if " with " in pattern:
          allowedWith = true
    for pattern in settings.denied:
      if pattern.matches(node):
        deniedHit = true
    # an explicitly allowed `X WITH exception` overrides a broader denial of X
    if (deniedHit and not allowedWith) or (len(settings.allowed) > 0 and not allowedHit):
      offending.add(if node.exception == "": node.id else: node.id & " WITH " & node.exception)
      return vDenied
    return vAllowed
  of lnAnd:
    result = vAllowed
    for child in node.children:
      result = max(result, settings.licenseVerdict(child, offending))
  of lnOr:
    var failed: seq[string]
    result = vDenied
    for child in node.children:
      let verdict = settings.licenseVerdict(child, failed)
      result = min(result, verdict)
    if result == vDenied:
      offending.add(failed)

proc normalizePattern(value: string): string =
  ## lowercase, with license names normalized like those of the SBOM
  if value.isGlob():
    return value.toLowerAscii()
  let i = value.toLowerAscii().find(" with ")
  if i >= 0:
    return (normalizeLicense(value[0 ..< i]) & " with " & value[i + 6 .. ^1].strip()).toLowerAscii()
  normalizeLicense(value).toLowerAscii()

proc expandPatterns(values: seq[string], path: string): seq[string] =
  ## `path` names the setting in errors, e.g. `policy.licenses.denied`
  for value in values:
    let value = value.strip()
    if not value.startsWith("@"):
      result.add(value.normalizePattern())
      continue
    let preset = value[1 .. ^1]
    if preset notin licensePresets:
      raise newException(ValueError, path & ": unknown preset " & value &
                                     ", expected one of @" &
                                     licensePresets.keys().toSeq().sorted().join(", @"))
    for pattern in licensePresets[preset]:
      result.add(pattern.toLowerAscii())

proc purlType(purl: string): string =
  if not purl.startsWith("pkg:"):
    return ""
  let slash = purl.find('/')
  if slash < 0:
    return ""
  purl[4 ..< slash].toLowerAscii()

proc purlBase(purl: string): string =
  ## the purl without version, qualifiers and subpath
  result = purl
  for sep in ['#', '?', '@']:
    let i = result.find(sep)
    if i >= 0:
      result = result[0 ..< i]

proc subject*(pkg: SbomPackage): string =
  if pkg.purl != "":
    return pkg.purl
  if pkg.version != "":
    return pkg.name & "@" & pkg.version
  pkg.name

proc isException(settings: LicensesConfig, pkg: SbomPackage): bool =
  let
    subject = pkg.subject().toLowerAscii()
    base    = pkg.purl.purlBase().toLowerAscii()
  for pattern in settings.exceptions:
    if globMatch(pattern, subject):
      return true
    # a pattern without version matches every version
    if '@' notin pattern and base != "" and globMatch(pattern, base):
      return true
  return false

proc isIgnoredType(settings: LicensesConfig, pkg: SbomPackage): bool =
  let types = [pkg.purl.purlType(), pkg.pkgType.toLowerAscii()]
  for t in types:
    if t == "":
      continue
    if t in settings.ignoreTypes:
      return true
    if not settings.includeOsPackages and t in osPackageTypes:
      return true
  return false

proc checkPackage*(settings: LicensesConfig, pkg: SbomPackage): Option[PolicyFinding] =
  if settings.isIgnoredType(pkg) or settings.isException(pkg):
    return none(PolicyFinding)
  var
    verdict   = vAllowed
    offending = newSeq[string]()
    written   = newSeq[string]()
  for license in pkg.licenses:
    if license.strip() == "":
      continue
    written.add(license)
    verdict = max(verdict, settings.licenseVerdict(parseLicenseExpression(license), offending))
  if len(written) == 0:
    verdict = vUnknown
  let expression = written.join(" AND ")
  case verdict
  of vAllowed:
    return none(PolicyFinding)
  of vDenied:
    var unique: seq[string]
    for license in offending:
      if license notin unique:
        unique.add(license)
    var reason = "license " & unique.join(", ") & " is not allowed"
    if len(unique) != 1 or unique[0] != expression:
      reason &= " (" & expression & ")"
    if settings.message != "":
      reason &= ". " & settings.message
    return some(newSubjectFinding(ruleName, "violation", pkg.subject(), reason, pkg.location))
  of vUnknown:
    if settings.unknown == "ignore":
      return none(PolicyFinding)
    let
      kind   = if settings.unknown == "error": "error" else: "violation"
      reason = if expression == "": "license is unknown"
               else: "license is unknown (" & expression & ")"
    return some(newSubjectFinding(ruleName, kind, pkg.subject(), reason, pkg.location))

# SBOM parsing

proc cyclonedxLocation(component: JsonNode): string =
  for prop in component{"properties"}.getElems():
    if prop{"name"}.getStr().startsWith("syft:location:") and
       prop{"name"}.getStr().endsWith(":path"):
      return prop{"value"}.getStr()

proc cyclonedxType(component: JsonNode): string =
  for prop in component{"properties"}.getElems():
    if prop{"name"}.getStr() == "syft:package:type":
      return prop{"value"}.getStr()

proc addCyclonedx(packages: var seq[SbomPackage], components: JsonNode) =
  # https://cyclonedx.org/docs/1.6/json/#components_items_licenses
  for component in components.getElems():
    if len(packages) > maxPackages:
      return
    packages.addCyclonedx(component{"components"})
    if component{"type"}.getStr() == "file":
      continue
    var pkg = SbomPackage(
      name:     component{"name"}.getStr(),
      version:  component{"version"}.getStr(),
      purl:     component{"purl"}.getStr(),
      pkgType:  component.cyclonedxType(),
      location: component.cyclonedxLocation(),
    )
    for entry in component{"licenses"}.getElems():
      if entry{"expression"}.getStr() != "":
        pkg.licenses.add(entry{"expression"}.getStr())
      elif entry{"license"}{"id"}.getStr() != "":
        pkg.licenses.add(entry{"license"}{"id"}.getStr())
      elif entry{"license"}{"name"}.getStr() != "":
        pkg.licenses.add(entry{"license"}{"name"}.getStr())
    packages.add(pkg)

proc spdxPurl(pkg: JsonNode): string =
  for reference in pkg{"externalRefs"}.getElems():
    if reference{"referenceType"}.getStr() == "purl":
      return reference{"referenceLocator"}.getStr()

proc spdxLocation(pkg: JsonNode): string =
  # syft writes "acquired package info from <cataloger>: <path>"
  let info = pkg{"sourceInfo"}.getStr()
  let i = info.rfind(": /")
  if i >= 0:
    return info[i + 2 .. ^1].split(", ")[0]

proc addSpdx(packages: var seq[SbomPackage], doc: JsonNode) =
  # https://spdx.github.io/spdx-spec/v2.3/package-information/#713-concluded-license-field
  for item in doc{"packages"}.getElems():
    if len(packages) > maxPackages:
      return
    let purl = item.spdxPurl()
    # the described directory or image itself, not a package
    if purl == "" and item{"versionInfo"}.getStr() == "":
      continue
    var pkg = SbomPackage(
      name:     item{"name"}.getStr(),
      version:  item{"versionInfo"}.getStr(),
      purl:     purl,
      location: item.spdxLocation(),
    )
    let concluded = item{"licenseConcluded"}.getStr()
    let license =
      if not concluded.isUnknownLicense(): concluded
      else: item{"licenseDeclared"}.getStr()
    if not license.isUnknownLicense():
      pkg.licenses.add(license)
    packages.add(pkg)

proc addSyftJson(packages: var seq[SbomPackage], doc: JsonNode) =
  # https://github.com/anchore/syft/tree/main/schema/json
  for artifact in doc{"artifacts"}.getElems():
    if len(packages) > maxPackages:
      return
    var pkg = SbomPackage(
      name:    artifact{"name"}.getStr(),
      version: artifact{"version"}.getStr(),
      purl:    artifact{"purl"}.getStr(),
      pkgType: artifact{"type"}.getStr(),
    )
    let locations = artifact{"locations"}.getElems()
    if len(locations) > 0:
      pkg.location = locations[0]{"path"}.getStr()
    for license in artifact{"licenses"}.getElems():
      let expression = license{"spdxExpression"}.getStr()
      pkg.licenses.add(if expression != "": expression else: license{"value"}.getStr())
    packages.add(pkg)

proc sbomPackages*(doc: JsonNode): seq[SbomPackage] =
  ## Packages of a CycloneDX, SPDX or syft JSON document. Raises `ValueError`
  ## for anything else.
  if doc == nil or doc.kind != JObject:
    raise newException(ValueError, "SBOM is not a JSON object")
  if doc{"bomFormat"}.getStr() == "CycloneDX":
    result.addCyclonedx(doc{"components"})
  elif doc.hasKey("spdxVersion"):
    result.addSpdx(doc)
  elif doc.hasKey("artifacts"):
    result.addSyftJson(doc)
  else:
    raise newException(ValueError, "unsupported SBOM format, expected CycloneDX, SPDX or syft JSON")
  if len(result) > maxPackages:
    raise newException(ValueError, "SBOM lists more than " & $maxPackages & " packages")

proc sbomDocuments*(sbom: Box): seq[JsonNode] =
  ## the documents of an `SBOM` key, which maps each tool to its output
  let parsed = parseJson(boxToJson(sbom))
  if parsed.kind != JObject:
    raise newException(ValueError, "SBOM key is not a JSON object")
  for _, doc in parsed.pairs():
    result.add(doc)

# SBOM collection

proc runSbomToolsOn(dir: string): seq[JsonNode] =
  ## Runs the enabled SBOM tools (syft by default) like `run_sbom_tools`
  ## would, stopping at the first that produces an SBOM.
  var tools: seq[(int, string)]
  for name in getChalkSubsections("tool"):
    let base = "tool." & name
    if attrGet[bool](base & ".enabled") and attrGet[string](base & ".kind") == "sbom":
      tools.add((attrGet[int](base & ".priority"), name))
  tools.sort()
  for (_, tool) in tools:
    try:
      let data = runTool(tool, dir, force = true)
      if "SBOM" in data:
        return @[parseJson(boxToJson(data["SBOM"]))]
    except CatchableError:
      error("policy: licenses: " & tool & " failed on " & dir & ": " & getCurrentExceptionMsg())

type SbomRunner* = proc(dir: string): seq[JsonNode] {.closure.}

var
  ## replaced by unit tests
  sbomRunner*: SbomRunner = runSbomToolsOn
  # with several policies the rule runs once per policy, the tools only once
  sbomCache   = initTable[string, seq[JsonNode]]()

proc contextSboms(dir: string): seq[JsonNode] =
  if dir notin sbomCache:
    sbomCache[dir] = sbomRunner(dir)
  sbomCache[dir]

proc clearLicensesCache*() =
  sbomCache.clear()

proc collectFindings(settings: LicensesConfig, docs: seq[JsonNode],
                     findings: var seq[PolicyFinding], seen: var HashSet[string]) =
  for doc in docs:
    for pkg in doc.sbomPackages():
      let finding = settings.checkPackage(pkg)
      if finding.isNone():
        continue
      let f = finding.get()
      let key = f.kind & "\0" & f.subject & "\0" & f.reason
      if key in seen:
        continue
      seen.incl(key)
      findings.add(f)

proc capFindings(findings: seq[PolicyFinding]): seq[PolicyFinding] =
  if len(findings) <= maxFindings:
    return findings
  result = findings[0 ..< maxFindings]
  var violations = 0
  for f in findings[maxFindings .. ^1]:
    if f.kind == "violation":
      inc(violations)
  let kind = if violations > 0: "violation" else: "error"
  result.add(newSubjectFinding(ruleName, kind, "",
                               $(len(findings) - maxFindings) & " more packages not shown"))

proc check*(settings: LicensesConfig, input: PolicyInput): seq[PolicyFinding] =
  var seen = initHashSet[string]()
  if input.command == "push":
    # licenses are checked at build time; marks only carry an SBOM when
    # the mark template records it
    for mark in input.pushMarks:
      if mark != nil and "SBOM" in mark:
        settings.collectFindings(mark["SBOM"].sbomDocuments(), result, seen)
    return result.capFindings()
  var docs: seq[JsonNode]
  if input.host != nil and "SBOM" in input.host:
    docs = input.host["SBOM"].sbomDocuments()
  else:
    if len(input.contextDirs) == 0:
      return @[newSubjectFinding(ruleName, "error", "",
                                 "no local build context to generate an SBOM from")]
    for dir in input.contextDirs[0 ..< min(len(input.contextDirs), maxContextDirs)]:
      let sboms = contextSboms(dir)
      if len(sboms) == 0:
        result.add(newSubjectFinding(ruleName, "error", dir,
                                     "could not generate an SBOM of the build context"))
      docs.add(sboms)
  settings.collectFindings(docs, result, seen)
  return result.capFindings()

# configuration

proc loadLicensesConfig*(): Option[LicensesConfig] =
  if not policyBoolSetting([ruleName, "enabled"], false):
    return none(LicensesConfig)
  let unknown = policyStringSetting([ruleName, "unknown"], "ignore")
  if unknown notin unknownChoices:
    raise newException(ValueError, "policy.licenses.unknown must be one of " & $unknownChoices)
  var settings = LicensesConfig(
    denied:            policyStringsSetting([ruleName, "denied"]).expandPatterns("policy.licenses.denied"),
    configuredAllowed: policyStringsSetting([ruleName, "allowed"]),
    unknown:           unknown,
    includeOsPackages: policyBoolSetting([ruleName, "include_os_packages"], false),
    message:           policyStringSetting([ruleName, "message"], ""),
  )
  settings.allowed = settings.configuredAllowed.expandPatterns("policy.licenses.allowed")
  for pattern in policyStringsSetting([ruleName, "exceptions"]):
    settings.exceptions.add(pattern.strip().toLowerAscii())
  for t in policyStringsSetting([ruleName, "ignore_types"]):
    settings.ignoreTypes.add(t.strip().toLowerAscii())
  return some(settings)

const licensesJsonFields = [
  PolicyJsonField(name: "enabled",             kind: JBool),
  PolicyJsonField(name: "denied",              kind: JArray),
  PolicyJsonField(name: "allowed",             kind: JArray),
  PolicyJsonField(name: "unknown",             kind: JString, choices: @unknownChoices),
  PolicyJsonField(name: "exceptions",          kind: JArray),
  PolicyJsonField(name: "ignore_types",        kind: JArray),
  PolicyJsonField(name: "include_os_packages", kind: JBool),
  PolicyJsonField(name: "message",             kind: JString),
]

proc validateLicensesJson(node: JsonNode, path: string) =
  node.validateFields(licensesJsonFields, path)
  for field in ["denied", "allowed", "exceptions", "ignore_types"]:
    var values: seq[string]
    for entry in node{field}.getElems():
      if entry.kind != JString:
        raise newException(ValueError, path & field & " entries must be strings")
      values.add(entry.getStr())
    if field in ["denied", "allowed"]:
      discard values.expandPatterns(path & field)

registerPolicyJsonSection(ruleName, validateLicensesJson)

var loaded: LicensesConfig

proc loadLicenses(): bool =
  let settings = loadLicensesConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome()

proc checkLicenses(input: PolicyInput): seq[PolicyFinding] =
  loaded.check(input)

proc licensesHint(): PolicyHint =
  # without a message the step summary would suggest using an allowed image
  if loaded.message == "":
    return PolicyHint()
  PolicyHint(rule: ruleName, message: loaded.message, allowed: loaded.configuredAllowed)

proc loadLicensesRule*() =
  newPolicyInputRule(ruleName, loadLicenses, checkLicenses, hint = licensesHint)
