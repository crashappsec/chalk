import std/[json, os, strutils]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/api
import ../../src/policy/engine
import ../../src/policy/sbom
import ../../src/policy/tools
import ../../src/policy/rules/licenses

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

let fixtures = currentSourcePath().parentDir() / "fixtures"

proc fixture(name: string): JsonNode =
  let file = if name == "cyclonedx": "sbom_licenses_cyclonedx.json" else: "sbom_" & name & ".json"
  parseJson(readFile(fixtures / file))

proc hostInput(doc: JsonNode): PolicyInput =
  ## chalk's SBOM of /ctx, the build context
  let host = ChalkDict()
  let sbom = newJObject()
  sbom["syft"] = doc
  host["SBOM"] = nimJsonToBox(sbom)
  PolicyInput(command: "build", contextDirs: @["/ctx"], host: host)

proc config(json: string): LicensesConfig =
  setPolicyJson("""{"mode": "audit", "licenses": """ & json & "}")
  let policies = policyConfigs()
  doAssert policies[0].configError == "", policies[0].configError
  selectPolicy(policies[0])
  result = loadLicensesConfig().get()
  setPolicyJson("")

proc findings(settings: LicensesConfig, doc: JsonNode): seq[(string, string, string)] =
  ## (kind, subject, reason) of every finding
  for f in settings.check(hostInput(doc)):
    doAssert f.rule == "licenses"
    result.add((f.kind, f.subject, f.reason))

proc verdict(settings: LicensesConfig, expression: string): Verdict =
  var offending: seq[string]
  settings.licenseVerdict(parseLicenseExpression(expression), offending)

proc testNormalize() =
  for (name, expected) in [
    ("MIT", "MIT"),
    ("The MIT License", "MIT"),
    ("Apache 2.0", "Apache-2.0"),
    ("Apache License, Version 2.0", "Apache-2.0"),
    ("Apache-2.0", "Apache-2.0"),
    ("GPLv2", "GPL-2.0-only"),
    ("GPL-2.0", "GPL-2.0-only"),
    ("GPL-2.0+", "GPL-2.0-or-later"),
    ("GPL-3.0-or-later", "GPL-3.0-or-later"),
    ("GNU General Public License v3 or later (GPLv3+)", "GPL-3.0-or-later"),
    ("GNU Lesser General Public License v2.1", "LGPL-2.1-only"),
    ("LGPL-2.1+", "LGPL-2.1-or-later"),
    ("AGPLv3", "AGPL-3.0-only"),
    ("BSD 3-Clause", "BSD-3-Clause"),
    ("MPL 2.0", "MPL-2.0"),
    ("EPL-1.0", "EPL-1.0"),
    ("LicenseRef-Apache-License-2.0", "Apache-2.0"),
    ("LicenseRef-Proprietary", "LicenseRef-Proprietary"),
    ("Python-2.0", "Python-2.0"),
    ("MIT-0", "MIT-0"),
    ("0BSD", "0BSD"),
    # unversioned GNU licenses allow any version
    ("GPL", "GPL-1.0-or-later"),
    ("GNU GPL", "GPL-1.0-or-later"),
    ("GNU General Public License", "GPL-1.0-or-later"),
    ("LGPL", "LGPL-2.0-or-later"),
    ("GNU Lesser General Public License", "LGPL-2.0-or-later"),
    ("AGPL", "AGPL-1.0-or-later"),
    ("LicenseRef-GPL", "GPL-1.0-or-later"),
    ("EUPL 1.2", "EUPL-1.2"),
    ("European Union Public Licence 1.2", "EUPL-1.2"),
    ("EUPL-1.1", "EUPL-1.1"),
    ("Common Development and Distribution License 1.0", "CDDL-1.0"),
    ("Unlicense", "Unlicense"),
    ("The Unlicense", "Unlicense"),
    ("UNLICENSED", "UNLICENSED"),
    ("GPL-2.0-with-classpath-exception", "GPL-2.0-only WITH Classpath-exception-2.0"),
    ("GPL-2.0-with-GCC-exception", "GPL-2.0-only WITH GCC-exception-2.0"),
    ("GPL-3.0-with-GCC-exception", "GPL-3.0-only WITH GCC-exception-3.1"),
    ("GPL-3.0-with-autoconf-exception", "GPL-3.0-only WITH Autoconf-exception-3.0"),
  ]:
    assertEq(normalizeLicense(name), expected)

proc testExpressions() =
  let node = parseLicenseExpression("MIT OR (Apache-2.0 AND GPL-2.0-only WITH Classpath-exception-2.0)")
  doAssert node.kind == lnOr and len(node.children) == 2
  doAssert node.children[1].kind == lnAnd
  doAssert node.children[1].children[1].exception == "Classpath-exception-2.0"
  # not an expression, a license name
  let name = parseLicenseExpression("Apache License 2.0")
  doAssert name.kind == lnLicense and name.id == "Apache-2.0"
  doAssert parseLicenseExpression("(MIT").kind == lnLicense

  let denied = config("""{"enabled": true, "denied": ["@strong_copyleft"]}""")
  assertEq(denied.verdict("MIT"), vAllowed)
  assertEq(denied.verdict("GPL-3.0-only"), vDenied)
  assertEq(denied.verdict("gpl-3.0-only"), vDenied)
  assertEq(denied.verdict("GPLv2"), vDenied)
  assertEq(denied.verdict("LGPL-2.1-only"), vAllowed)
  assertEq(denied.verdict("MIT OR GPL-2.0"), vAllowed)
  assertEq(denied.verdict("MIT AND GPL-2.0"), vDenied)
  assertEq(denied.verdict("(MIT OR GPL-2.0) AND AGPL-3.0-only"), vDenied)
  assertEq(denied.verdict("GPL-2.0-only WITH Classpath-exception-2.0"), vDenied)
  assertEq(denied.verdict("NOASSERTION"), vUnknown)
  assertEq(denied.verdict("MIT OR NOASSERTION"), vAllowed)
  assertEq(denied.verdict("MIT AND NOASSERTION"), vUnknown)
  assertEq(denied.verdict("GPL-3.0-only AND NOASSERTION"), vDenied)
  var offending: seq[string]
  discard denied.licenseVerdict(parseLicenseExpression("MIT AND (GPL-2.0 OR AGPL-3.0)"), offending)
  assertEq(offending, @["GPL-2.0-only", "AGPL-3.0-only"])
  # `or later` continues a license rather than offering `later` as an alternative
  for name in ["GPL-2.0 or later", "GPLv3 or later", "GPL-2.0 OR later", "(GPL-2.0 or newer)",
               "LGPL-2.1 or greater AND GPL-3.0 or later"]:
    doAssert denied.verdict(name) == vDenied, name
  assertEq(parseLicenseExpression("GPL-2.0 or later").id, "GPL-2.0-or-later")
  assertEq(parseLicenseExpression("LGPL-2.1 or newer").id, "LGPL-2.1-or-later")
  assertEq(denied.verdict("MIT or GPL-2.0 or later"), vAllowed)
  let orLater = parseLicenseExpression("MIT OR GPL-2.0 or later WITH Classpath-exception-2.0")
  doAssert orLater.kind == lnOr and len(orLater.children) == 2
  assertEq(orLater.children[1].id, "GPL-2.0-or-later")
  assertEq(orLater.children[1].exception, "Classpath-exception-2.0")

  # an explicitly allowed exception overrides a broader denial
  let classpath = config("""{"enabled": true, "denied": ["GPL-*"],
                             "allowed": ["MIT", "GPL-2.0-only WITH Classpath-exception-2.0"]}""")
  assertEq(classpath.verdict("GPL-2.0-only WITH Classpath-exception-2.0"), vAllowed)
  assertEq(classpath.verdict("GPL-2.0-only"), vDenied)
  assertEq(classpath.verdict("GPL-2.0-only WITH GCC-exception-2.0"), vDenied)
  assertEq(classpath.verdict("Apache-2.0"), vDenied)

  # allowlist entries are normalized like the SBOM's licenses
  let allowed = config("""{"enabled": true, "allowed": ["Apache 2.0", "BSD-*", "mit"]}""")
  assertEq(allowed.verdict("Apache-2.0"), vAllowed)
  assertEq(allowed.verdict("BSD-3-Clause"), vAllowed)
  assertEq(allowed.verdict("MIT"), vAllowed)
  assertEq(allowed.verdict("ISC"), vDenied)
  assertEq(allowed.verdict("Custom license"), vDenied)

proc testExpressionLimits() =
  ## SBOM strings are untrusted: nesting would exhaust the stack while parsing
  let denied = config("""{"enabled": true, "denied": ["GPL-*"]}""")
  let nested = repeat('(', 100_000) & "MIT" & repeat(')', 100_000)
  doAssertRaises(LicenseExpressionError):
    discard parseLicenseExpression(nested)
  doAssertRaises(LicenseExpressionError):
    discard parseLicenseExpression(repeat("MIT AND ", 10_000) & "MIT")
  doAssert parseLicenseExpression(repeat('(', 32) & "MIT" & repeat(')', 32)).id == "MIT"
  # unbalanced parentheses still are a license name, not an error
  doAssert parseLicenseExpression(repeat(')', 100) & "MIT").kind == lnLicense
  proc checked(licenses: seq[string]): (string, string) =
    let pkg = SbomPackage(name: "x", version: "1", purl: "pkg:npm/x@1", licenses: licenses)
    let f = denied.checkPackage(pkg)
    if f.isNone(): ("", "") else: (f.get().kind, f.get().reason)
  # an expression that cannot be evaluated is an error, not a license name
  let deep = repeat('(', 1000) & "GPL-3.0-only" & repeat(')', 1000)
  assertEq(checked(@[deep]), ("error", "license expression nests more than 32 parentheses"))
  assertEq(checked(@[nested]), ("error", "license expression is longer than 65536 bytes"))
  assertEq(checked(@["MIT", deep])[0], "error")
  # unless another license is denied
  let (kind, reason) = checked(@[nested, "GPL-3.0-only"])
  assertEq(kind, "violation")
  doAssert len(reason) < 1200, $len(reason)

proc testUnrecognizedCopyleft() =
  let strong = config("""{"enabled": true, "denied": ["@strong_copyleft"]}""")
  for name in ["GPL", "GNU GPL", "GNU General Public License", "AGPL",
               "EUPL 1.2", "European Union Public Licence 1.2",
               "GPL v2+ with some notice", "GNU GPL v3 (see COPYING)",
               "GPL-2.0-with-classpath-exception"]:
    doAssert strong.verdict(name) == vDenied, name
  for name in ["LGPL", "LGPL v2.1 with linking notice", "GPL compatible",
               "MPLUS-1", "MIT"]:
    doAssert strong.verdict(name) == vAllowed, name
  let weak = config("""{"enabled": true, "denied": ["@weak_copyleft"]}""")
  for name in ["LGPL", "LGPL v2.1 with linking notice", "MPL", "Mozilla Public License"]:
    doAssert weak.verdict(name) == vDenied, name
  doAssert weak.verdict("GPL v2+ with some notice") == vAllowed
  # a family only matches family globs, not a version
  let gpl3 = config("""{"enabled": true, "denied": ["GPL-3.0*"]}""")
  assertEq(gpl3.verdict("GPL v2+ with some notice"), vAllowed)
  let classpath = config("""{"enabled": true, "denied": ["GPL-*"],
                             "allowed": ["MIT", "GPL-2.0-only WITH Classpath-exception-2.0"]}""")
  assertEq(classpath.verdict("GPL-2.0-with-classpath-exception"), vAllowed)
  let unlicense = config("""{"enabled": true, "allowed": ["The Unlicense"]}""")
  assertEq(unlicense.verdict("Unlicense"), vAllowed)
  assertEq(unlicense.verdict("UNLICENSED"), vUnknown)

proc testNpmNonLicenses() =
  let allowlist = config("""{"enabled": true, "allowed": ["MIT"]}""")
  for name in ["UNLICENSED", "SEE LICENSE IN LICENSE.md", "see license in ./EULA"]:
    doAssert allowlist.verdict(name) == vUnknown, name
  let pkg = SbomPackage(name: "app", version: "1.0.0", purl: "pkg:npm/app@1.0.0",
                        licenses: @["UNLICENSED"])
  doAssert allowlist.checkPackage(pkg).isNone()
  let unknown = config("""{"enabled": true, "allowed": ["MIT"], "unknown": "violation"}""")
  assertEq(unknown.checkPackage(pkg).get().reason, "license is unknown (UNLICENSED)")

proc testExceptions() =
  let settings = config("""{"enabled": true, "denied": ["GPL-*"],
                            "exceptions": ["pkg:npm/@scope/x", "pkg:pypi/Foo_Bar",
                                           "pkg:npm/ranged@<2", "legacy-*"]}""")
  proc exempt(purl: string, name = ""): bool =
    let pkg = SbomPackage(name: name, version: "1.0.0", purl: purl,
                          licenses: @["GPL-3.0-only"])
    settings.checkPackage(pkg).isNone()
  doAssert exempt("pkg:npm/%40scope/x@1.0.0")
  doAssert exempt("pkg:npm/@scope/x@1.0.0")
  doAssert exempt("pkg:pypi/foo-bar@1.0?arch=x86_64")
  doAssert exempt("pkg:npm/ranged@1.9.0")
  doAssert not exempt("pkg:npm/ranged@2.0.0")
  # a version that cannot be compared with the range does not exempt
  doAssert not exempt("pkg:npm/ranged@latest")
  doAssert not exempt("pkg:npm/@scope/y@1.0.0")
  # other patterns are globs of the package name (`name@version`)
  doAssert exempt("", "legacy-tool")
  doAssert not exempt("", "tool")
  # and of the purl without version, an unencoded npm scope included
  let globs = config("""{"enabled": true, "denied": ["GPL-*"], "exceptions": ["*/@scope/x"]}""")
  for purl in ["pkg:npm/@scope/x@1.0.0", "pkg:npm/@scope/x@1.0.0#lib", "pkg:npm/@scope/x"]:
    let pkg = SbomPackage(name: "x", version: "1.0.0", purl: purl, licenses: @["GPL-3.0-only"])
    doAssert globs.checkPackage(pkg).isNone(), purl

proc testSourceIsNotAPackage() =
  ## the scanned project itself, as an SBOM describes it, is not a dependency
  let cyclonedx = %*{"bomFormat": "CycloneDX",
                     "metadata": {"component": {"type": "application", "name": "myapp",
                                                "purl": "pkg:npm/myapp@1.0.0",
                                                "licenses": [{"license": {"id": "GPL-3.0-only"}}]}},
                     "components": []}
  assertEq(len(parseSbom(cyclonedx).packages), 0)
  let syft = %*{"artifacts": [],
                "source": {"type": "directory", "name": "myapp", "metadata": {"path": "/ctx"}}}
  assertEq(len(parseSbom(syft).packages), 0)

proc testRegistration() =
  loadLicensesRule()
  var found = false
  for rule in policyRules():
    if rule.name == "licenses":
      found = true
      # context directories are only collected for such rules
      doAssert rule.requiresContext
  doAssert found

proc testCycloneDx() =
  let doc = fixture("cyclonedx")
  let packages = parseSbom(doc).packages
  # file components are not packages
  for pkg in packages:
    doAssert not pkg.name.startsWith("/"), pkg.name
  let denied = config("""{"enabled": true, "denied": ["@strong_copyleft"]}""")
  assertEq(denied.findings(doc), @[
    ("violation", "pkg:npm/gplpkg@1.0.0", "license GPL-3.0-only is not allowed"),
    ("violation", "pkg:pypi/legacy@0.1.0",
     "license GPL-3.0-or-later is not allowed (GNU General Public License v3 or later (GPLv3+))"),
  ])
  # OS packages come with the base image and are ignored by default
  let withOs = config("""{"enabled": true, "denied": ["@strong_copyleft"], "include_os_packages": true}""")
  let osFindings = withOs.findings(doc)
  assertEq(len(osFindings), 3)
  doAssert osFindings[1][1].startsWith("pkg:apk/alpine/busybox@")

  let allowlist = config("""{"enabled": true, "allowed": ["MIT", "Apache-2.0"], "message": "See go/licenses"}""")
  assertEq(allowlist.findings(doc), @[
    ("violation", "pkg:npm/gplpkg@1.0.0", "license GPL-3.0-only is not allowed. See go/licenses"),
    ("violation", "pkg:maven/javax.annotation/javax.annotation-api@1.3.2",
     "license CDDL-1.1, GPL-2.0-only WITH Classpath-exception-2.0 is not allowed " &
     "(CDDL-1.1 OR GPL-2.0-only WITH Classpath-exception-2.0). See go/licenses"),
    ("violation", "pkg:pypi/legacy@0.1.0",
     "license GPL-3.0-or-later is not allowed (GNU General Public License v3 or later (GPLv3+)). See go/licenses"),
  ])

  let unknown = config("""{"enabled": true, "unknown": "violation"}""")
  assertEq(unknown.findings(doc), @[
    ("violation", "pkg:golang/github.com/pkg/errors@v0.9.1", "license is unknown"),
    ("violation", "pkg:pypi/unknownpkg@2.0.0", "license is unknown (UNKNOWN)"),
  ])
  let unknownError = config("""{"enabled": true, "unknown": "error", "ignore_types": ["pypi"]}""")
  assertEq(unknownError.findings(doc), @[
    ("error", "pkg:golang/github.com/pkg/errors@v0.9.1", "license is unknown"),
  ])

  let exceptions = config("""{"enabled": true, "denied": ["GPL-*"],
                              "exceptions": ["pkg:npm/gplpkg", "pkg:pypi/legacy@9.*"]}""")
  assertEq(exceptions.findings(doc), @[
    ("violation", "pkg:pypi/legacy@0.1.0",
     "license GPL-3.0-or-later is not allowed (GNU General Public License v3 or later (GPLv3+))"),
  ])

proc testFormats() =
  let settings = config("""{"enabled": true, "denied": ["GPL-3.0*"]}""")
  for format in ["cyclonedx", "spdx", "syft"]:
    let found = settings.check(hostInput(fixture(format)))
    doAssert len(found) >= 1, format
    assertEq(found[0].subject, "pkg:npm/gplpkg@1.0.0")
    # relative to the build context
    assertEq(found[0].location, "package-lock.json")
  # chalk scans the repository containing the context: only packages inside
  # the context directory count
  var monorepo = hostInput(fixture("cyclonedx"))
  monorepo.contextDirs = @["/ctx/libs"]
  let inLibs = config("""{"enabled": true, "allowed": ["MIT"]}""").check(monorepo)
  assertEq(len(inLibs), 1)
  assertEq(inLibs[0].subject, "pkg:maven/javax.annotation/javax.annotation-api@1.3.2")
  assertEq(inLibs[0].location, "javax.annotation-api-1.3.2.jar")

proc testCollection() =
  let settings = config("""{"enabled": true, "denied": ["GPL-3.0-only"]}""")
  var runs = 0
  policyToolRunner = proc(request: ToolRequest, dir: string): seq[ToolOutput] =
    inc(runs)
    if dir != "/ctx":
      raise newException(ValueError, "syft produced no SBOM")
    @[ToolOutput(tool: "syft", root: dir, value: fixture("cyclonedx"))]
  clearPolicyToolCache()
  # generated on demand when the SBOM tools did not run, once per directory
  let input = PolicyInput(command: "build", contextDirs: @["/ctx"], host: ChalkDict())
  assertEq(len(settings.check(input)), 1)
  assertEq(len(settings.check(input)), 1)
  assertEq(runs, 1)
  let failed = settings.check(PolicyInput(command: "build", contextDirs: @["/other"], host: ChalkDict()))
  assertEq(failed[0].kind, "error")
  assertEq(failed[0].subject, "/other")
  assertEq(failed[0].reason, "could not produce an SBOM of the build context: syft produced no SBOM")
  let noContext = settings.check(PolicyInput(command: "build", host: ChalkDict()))
  assertEq(noContext[0].kind, "error")

  # push only checks SBOMs recorded in the image marks
  let mark = ChalkDict()
  let sbom = newJObject()
  sbom["syft"] = fixture("syft")
  mark["SBOM"] = nimJsonToBox(sbom)
  let pushed = settings.check(PolicyInput(command: "push", pushMarks: @[mark, ChalkDict()]))
  assertEq(len(pushed), 1)
  assertEq(pushed[0].subject, "pkg:npm/gplpkg@1.0.0")
  assertEq(len(settings.check(PolicyInput(command: "push", pushMarks: @[ChalkDict()]))), 0)
  assertEq(runs, 2)

proc testFindingsAreCapped() =
  var components = newJArray()
  for i in 0 ..< 250:
    components.add(%*{"type": "library", "name": "p" & $i, "version": "1",
                      "purl": "pkg:npm/p" & $i & "@1",
                      "licenses": [{"license": {"id": "GPL-3.0-only"}}]})
  let doc = %*{"bomFormat": "CycloneDX", "metadata": {"component": {"name": "/ctx"}},
               "components": components}
  let found = config("""{"enabled": true, "denied": ["GPL-*"]}""").findings(doc)
  assertEq(len(found), 201)
  assertEq(found[^1], ("violation", "licenses", "50 more packages not listed"))

proc testJsonValidation() =
  proc rejects(json, reason: string) =
    let configs = parsePolicyJson("""{"policies": [{"id": "a", "licenses": """ & json & "}]}")
    doAssert reason in configs[0].configError, configs[0].configError
  rejects("""{"enabeld": true}""", "unknown field policy.policies[0].licenses.enabeld")
  rejects("""{"denied": "GPL-*"}""", "policy.policies[0].licenses.denied must be a array")
  rejects("""{"denied": [1]}""", "policy.policies[0].licenses.denied entries must be strings")
  rejects("""{"allowed": ["@copyleft"]}""",
          "policy.policies[0].licenses.allowed: unknown preset @copyleft, expected one of " &
          "@network_copyleft, @strong_copyleft, @weak_copyleft")
  rejects("""{"unknown": "block"}""", "policy.policies[0].licenses.unknown must be one of")
  rejects("""{"exceptions": ["pkg:npm/x@<>1"]}""",
          "policy.policies[0].licenses.exceptions: invalid purl pkg:npm/x@<>1")
  setPolicyJson("""{"mode": "audit", "licenses": {"enabled": false, "denied": ["GPL-*"]}}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadLicensesConfig().isNone()
  setPolicyJson("")

testNormalize()
testExpressions()
testExpressionLimits()
testUnrecognizedCopyleft()
testNpmNonLicenses()
testExceptions()
testSourceIsNotAPackage()
testRegistration()
testCycloneDx()
testFormats()
testCollection()
testFindingsAreCapped()
testJsonValidation()
