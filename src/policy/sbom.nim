##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## SBOMs for policy rules that check what a build depends on (packages,
## licenses). Reads the output of the `sbom` tools (`tool.syft`, CycloneDX
## JSON by default) collected by chalk (`SBOM` host key, `run_sbom_tools`),
## recorded in the chalk mark of a pushed image, or produced on demand for
## the build context (see policy/tools.nim). SPDX and syft JSON, which syft
## writes with other `syft_argv`, are read too.
## * https://cyclonedx.org/docs/1.6/json/
## * https://spdx.github.io/spdx-spec/v2.3/
## * https://github.com/anchore/syft/tree/main/schema/json

import std/[
  json,
  os,
  strutils,
]
import "."/[
  api,
  tools,
]

type
  SbomPackage* = object
    name*:     string
    version*:  string
    purl*:     string
    purlType*: string # e.g. npm, pypi, golang, maven, deb
    pkgType*:  string # syft package type when recorded, e.g. npm, python, go-module
    language*: string # e.g. javascript, python, go
    ## where the package was found: relative to the build context on build,
    ## to the directory chalk scanned when it built the image on push
    location*: string
    licenses*: seq[string] # SPDX ids, names or expressions as listed; each applies (AND)

  Sbom* = object
    source*:    string # what the SBOM describes, e.g. the scanned directory or image
    packages*:  seq[SbomPackage]
    truncated*: bool   # more than `maxSbomPackages` packages

  PolicySboms* = object
    sboms*:  seq[Sbom]
    errors*: seq[PolicyFinding]

const
  maxSbomPackages*  = 100_000
  maxComponentDepth = 8

# purl types (https://github.com/package-url/purl-spec/blob/main/PURL-TYPES.rst)
# whose language is unambiguous, for SBOMs without syft's language property
const purlLanguages = [
  ("npm",      "javascript"),
  ("pypi",     "python"),
  ("golang",   "go"),
  ("maven",    "java"),
  ("cargo",    "rust"),
  ("gem",      "ruby"),
  ("composer", "php"),
  ("nuget",    "dotnet"),
  ("pub",      "dart"),
  ("hackage",  "haskell"),
  ("cran",     "r"),
  ("swift",    "swift"),
  ("conan",    "cpp"),
]

proc purlType*(purl: string): string =
  ## lowercase type of `pkg:<type>/...`, empty when `purl` is not a purl
  if not purl.toLowerAscii().startsWith("pkg:"):
    return ""
  let rest = purl[4 .. ^1].strip(leading = true, trailing = false, chars = {'/'})
  let slash = rest.find('/')
  if slash <= 0:
    return ""
  return rest[0 ..< slash].toLowerAscii()

proc languageOf(purlType: string): string =
  for (t, lang) in purlLanguages:
    if t == purlType:
      return lang
  return ""

proc add(sbom: var Sbom, pkg: SbomPackage): bool =
  ## false once the SBOM is full
  if len(sbom.packages) >= maxSbomPackages:
    sbom.truncated = true
    return false
  var pkg = pkg
  pkg.purlType = pkg.purl.purlType()
  if pkg.language == "":
    pkg.language = languageOf(pkg.purlType)
  pkg.language = pkg.language.toLowerAscii()
  sbom.packages.add(pkg)
  return true

# CycloneDX

proc property(component: JsonNode, name: string): string =
  for p in component{"properties"}.getElems():
    if p{"name"}.getStr() == name:
      return p{"value"}.getStr()
  return ""

proc cyclonedxLicenses(component: JsonNode): seq[string] =
  # https://cyclonedx.org/docs/1.6/json/#components_items_licenses
  # each entry is either {"license": {"id"|"name"}} or {"expression"}
  for entry in component{"licenses"}.getElems():
    let expression = entry{"expression"}.getStr()
    if expression != "":
      result.add(expression)
      continue
    let license = entry{"license"}
    let id = license{"id"}.getStr()
    if id != "":
      result.add(id)
    elif license{"name"}.getStr() != "":
      result.add(license{"name"}.getStr())

proc addComponents(sbom: var Sbom, components: JsonNode, depth: int) =
  if depth > maxComponentDepth:
    return
  for component in components.getElems():
    if component.kind != JObject:
      continue
    let purl = component{"purl"}.getStr()
    # files and the scanned source itself are components too
    if purl != "" or component{"type"}.getStr() notin ["file", ""]:
      let added = sbom.add(SbomPackage(
        name:     component{"name"}.getStr(),
        version:  component{"version"}.getStr(),
        purl:     purl,
        pkgType:  component.property("syft:package:type"),
        language: component.property("syft:package:language"),
        location: component.property("syft:location:0:path"),
        licenses: component.cyclonedxLicenses(),
      ))
      if not added:
        return
    sbom.addComponents(component{"components"}, depth + 1)

proc parseCycloneDx(doc: JsonNode): Sbom =
  result.addComponents(doc{"components"}, 0)

# SPDX

proc isNoAssertion(license: string): bool =
  license == "" or license.toUpperAscii() in ["NOASSERTION", "NONE"]

proc spdxPurl(pkg: JsonNode): string =
  for reference in pkg{"externalRefs"}.getElems():
    if reference{"referenceType"}.getStr() == "purl":
      return reference{"referenceLocator"}.getStr()

proc spdxLocation(pkg: JsonNode): string =
  # syft writes "acquired package info from <cataloger>: <path>[, <path>]"
  let info = pkg{"sourceInfo"}.getStr()
  let i = info.rfind(": /")
  if i >= 0:
    return info[i + 2 .. ^1].split(", ")[0]

proc parseSpdx(doc: JsonNode): Sbom =
  for item in doc{"packages"}.getElems():
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
    # https://spdx.github.io/spdx-spec/v2.3/package-information/#713-concluded-license-field
    let concluded = item{"licenseConcluded"}.getStr()
    let license =
      if not concluded.isNoAssertion(): concluded
      else: item{"licenseDeclared"}.getStr()
    if not license.isNoAssertion():
      pkg.licenses.add(license)
    if not result.add(pkg):
      return

# syft JSON

proc parseSyftJson(doc: JsonNode): Sbom =
  for artifact in doc{"artifacts"}.getElems():
    var pkg = SbomPackage(
      name:     artifact{"name"}.getStr(),
      version:  artifact{"version"}.getStr(),
      purl:     artifact{"purl"}.getStr(),
      pkgType:  artifact{"type"}.getStr(),
      language: artifact{"language"}.getStr(),
    )
    let locations = artifact{"locations"}.getElems()
    if len(locations) > 0:
      pkg.location = locations[0]{"path"}.getStr()
    for license in artifact{"licenses"}.getElems():
      let expression = license{"spdxExpression"}.getStr()
      pkg.licenses.add(if expression != "": expression else: license{"value"}.getStr())
    if not result.add(pkg):
      return

proc describedSource(doc: JsonNode): string =
  ## what an SBOM says it describes, e.g. the directory syft scanned
  if doc{"bomFormat"}.getStr() == "CycloneDX":
    return doc{"metadata"}{"component"}{"name"}.getStr()
  if doc.hasKey("spdxVersion"):
    # syft names the document after what it scanned
    return doc{"name"}.getStr()
  let source = doc{"source"}
  return source{"metadata"}{"path"}.getStr(source{"target"}.getStr())

proc parseSbom*(doc: JsonNode, source = ""): Sbom =
  ## Packages of a CycloneDX, SPDX or syft JSON document. `source` overrides
  ## what the document says it describes. Raises `ValueError` for anything
  ## else.
  if doc == nil or doc.kind != JObject:
    raise newException(ValueError, "SBOM is not a JSON object")
  if doc{"bomFormat"}.getStr() == "CycloneDX":
    result = doc.parseCycloneDx()
  elif doc.hasKey("spdxVersion"):
    result = doc.parseSpdx()
  elif doc.hasKey("artifacts"):
    result = doc.parseSyftJson()
  else:
    raise newException(ValueError, "unsupported SBOM format, expected CycloneDX, SPDX or syft JSON")
  result.source = if source != "": source else: doc.describedSource()

proc forContext*(sbom: Sbom, root, dir: string): Sbom =
  ## Packages of an SBOM of `root` found within `dir`, with locations made
  ## relative to `dir`. Packages without a location are kept, as they could
  ## be anywhere.
  result = Sbom(source: dir, truncated: sbom.truncated)
  for pkg in sbom.packages:
    let location = pkg.location.contextPath(root, dir)
    if location.isNone():
      continue
    var p = pkg
    p.location = location.get()
    result.packages.add(p)

proc addOutput(result: var PolicySboms, rule: string, output: ToolOutput,
               root, dir: string) =
  try:
    var sbom = output.value.parseSbom(output.image)
    if dir != "":
      sbom = sbom.forContext(root, dir)
    else:
      for p in sbom.packages.mitems():
        p.location = p.location.strip(trailing = false, chars = {'/'})
    if sbom.truncated:
      result.errors.add(newSubjectFinding(rule, "error", sbom.source,
        "the SBOM lists more than " & $maxSbomPackages & " packages; only the first were checked"))
    result.sboms.add(sbom)
  except CatchableError:
    let where = if output.image != "": " in the chalk mark of " & output.image
                else: " of " & dir
    result.errors.add(newSubjectFinding(rule, "error", output.tool,
                                        "could not read the SBOM" & where & ": " &
                                        getCurrentExceptionMsg()))

proc hostSboms(input: PolicyInput, rule: string): ToolOutputs =
  ## chalk's SBOM, which covers the context directories below what it scanned
  try:
    result.outputs = input.host.toolOutputs("SBOM")
  except CatchableError:
    result.errors.add(newSubjectFinding(rule, "error", "SBOM",
                                        "could not read the SBOM chalk collected: " &
                                        getCurrentExceptionMsg()))
  for output in result.outputs.mitems():
    # without EXTERNAL_TOOL_DURATION, what the SBOM says it describes
    if output.root == "" and output.value.kind == JObject:
      let source = output.value.describedSource()
      if source.isAbsolute():
        output.root = source

proc policySboms*(input: PolicyInput, rule: string): PolicySboms =
  ## SBOMs of what the command builds or pushes. Errors are reported by
  ## `rule`.
  ##
  ## * build: per local build context directory, the SBOM chalk collected
  ##   when it covers the directory, else one produced on demand (cached for
  ##   the process). Only packages within the directory are kept, with
  ##   locations relative to it.
  ## * push: the SBOMs recorded in the pushed images' chalk marks; images
  ##   without one are skipped, as default chalk marks do not include it.
  if input.command == "push":
    let pushed = input.pushedToolOutputs(rule, "SBOM")
    result.errors = pushed.errors
    for output in pushed.outputs:
      result.addOutput(rule, output, "", "")
    return
  let request = ToolRequest(rule: rule, kind: "sbom", key: "SBOM", what: "an SBOM",
                            runTools: true, firstOnly: true)
  let host    = input.hostSboms(rule)
  let outputs = input.contextToolOutputs(request, host.outputs)
  result.errors = host.errors & outputs.errors
  for context in outputs.contexts:
    for output in context.outputs:
      result.addOutput(rule, output, output.root, context.dir)
