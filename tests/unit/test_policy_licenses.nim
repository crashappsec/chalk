import std/[json, os, strutils]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/engine
import ../../src/policy/rules/licenses

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

let fixtures = currentSourcePath().parentDir() / "fixtures"

proc fixture(name: string): JsonNode =
  parseJson(readFile(fixtures / ("policy_licenses_" & name & ".json")))

proc config(json: string): LicensesConfig =
  setPolicyJson("""{"mode": "audit", "licenses": """ & json & "}")
  let policies = policyConfigs()
  doAssert policies[0].configError == "", policies[0].configError
  selectPolicy(policies[0])
  result = loadLicensesConfig().get()
  setPolicyJson("")

proc findings(settings: LicensesConfig, doc: JsonNode): seq[(string, string, string)] =
  ## (kind, subject, reason) of every finding
  let host = ChalkDict()
  let sbom = newJObject()
  sbom["syft"] = doc
  host["SBOM"] = nimJsonToBox(sbom)
  for f in settings.check(PolicyInput(command: "build", host: host)):
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

proc testCycloneDx() =
  let doc = fixture("cyclonedx")
  let packages = sbomPackages(doc)
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
    let host = ChalkDict()
    let sbom = newJObject()
    sbom["syft"] = fixture(format)
    host["SBOM"] = nimJsonToBox(sbom)
    let found = settings.check(PolicyInput(command: "build", host: host))
    doAssert len(found) >= 1, format
    assertEq(found[0].subject, "pkg:npm/gplpkg@1.0.0")
    assertEq(found[0].location, "/package-lock.json")
  doAssertRaises(ValueError):
    discard sbomPackages(parseJson("""{"foo": 1}"""))

proc testCollection() =
  let settings = config("""{"enabled": true, "denied": ["GPL-3.0-only"]}""")
  var runs = 0
  sbomRunner = proc(dir: string): seq[JsonNode] =
    inc(runs)
    if dir == "/ctx":
      return @[fixture("cyclonedx")]
    return @[]
  clearLicensesCache()
  # generated on demand when the SBOM tools did not run, once per directory
  let input = PolicyInput(command: "build", contextDirs: @["/ctx"], host: ChalkDict())
  assertEq(len(settings.check(input)), 1)
  assertEq(len(settings.check(input)), 1)
  assertEq(runs, 1)
  let failed = settings.check(PolicyInput(command: "build", contextDirs: @["/other"], host: ChalkDict()))
  assertEq(failed[0].kind, "error")
  assertEq(failed[0].reason, "could not generate an SBOM of the build context")
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
  let doc = %*{"bomFormat": "CycloneDX", "components": components}
  let found = config("""{"enabled": true, "denied": ["GPL-*"]}""").findings(doc)
  assertEq(len(found), 201)
  assertEq(found[^1], ("violation", "", "50 more packages not shown"))

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
  setPolicyJson("""{"mode": "audit", "licenses": {"enabled": false, "denied": ["GPL-*"]}}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadLicensesConfig().isNone()
  setPolicyJson("")

testNormalize()
testExpressions()
testCycloneDx()
testFormats()
testCollection()
testFindingsAreCapped()
testJsonValidation()
