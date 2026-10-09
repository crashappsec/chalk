import std/[json, os, strutils]
import ../../src/types
import ../../src/policy/engine
import ../../src/policy/sbom
import ../../src/policy/tools
import ../../src/policy/rules/packages

const
  fixture = currentSourcePath().parentDir() / "fixtures" / "sbom_cyclonedx.json"
  configFixture = currentSourcePath().parentDir() / "fixtures" / "policy_config_packages.json"

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc matches(pattern, purl: string): PackageMatch =
  parsePackagePattern(pattern).matches(purl).result

proc testPurls() =
  assertEq(purlParts("pkg:npm/%40angular/core@16.0.0"), ("npm/@angular/core", "16.0.0"))
  assertEq(purlParts("pkg:npm/@angular/core"), ("npm/@angular/core", ""))
  assertEq(purlParts("pkg:deb/debian/libc6@1:2.36-9?arch=amd64#sub"), ("deb/debian/libc6", "1:2.36-9"))
  assertEq(purlParts("PKG:PyPI/Django_Rest.Framework@1.0"), ("pypi/django-rest-framework", "1.0"))
  assertEq(purlParts("pkg:golang/github.com/google/uuid@v1.6.0"), ("golang/github.com/google/uuid", "v1.6.0"))
  assertEq(purlType("pkg:golang/github.com/google/uuid@v1.6.0"), "golang")
  assertEq(purlType("not-a-purl"), "")

proc testPatterns() =
  for bad in ["npm/lodash", "pkg:npm", "pkg:npm/lodash@<abc", "pkg:npm/lodash@=>1", "pkg:npm/lodash@<1.2.3.4"]:
    try:
      discard parsePackagePattern(bad)
      doAssert false, "accepted " & bad
    except ValueError:
      discard
  assertEq(matches("pkg:npm/event-stream@3.3.6", "pkg:npm/event-stream@3.3.6"), pmMatch)
  assertEq(matches("pkg:npm/event-stream@3.3.6", "pkg:npm/event-stream@3.3.5"), pmNoMatch)
  assertEq(matches("pkg:npm/event-stream", "pkg:npm/event-stream@4.0.0"), pmMatch)
  assertEq(matches("pkg:npm/event-stream", "pkg:npm/event-stream-x@4.0.0"), pmNoMatch)
  assertEq(matches("pkg:pypi/*colourama*", "pkg:pypi/colourama@0.1.0"), pmMatch)
  assertEq(matches("pkg:pypi/django_rest", "pkg:pypi/django-rest@1.0"), pmMatch)
  assertEq(matches("pkg:*/lodash", "pkg:npm/lodash@4.17.20"), pmMatch)
  assertEq(matches("pkg:npm/@angular/*", "pkg:npm/%40angular/core@16.0.0"), pmMatch)
  assertEq(matches("pkg:npm/@angular/*@16.*", "pkg:npm/%40angular/core@16.0.0"), pmMatch)
  assertEq(matches("pkg:npm/@angular/*@15.*", "pkg:npm/%40angular/core@16.0.0"), pmNoMatch)
  assertEq(matches("pkg:golang/github.com/google/uuid@1.6.0", "pkg:golang/github.com/google/uuid@v1.6.0"), pmMatch)
  assertEq(matches("pkg:npm/lodash@<4.17.21", "pkg:npm/lodash@4.17.20"), pmMatch)
  assertEq(matches("pkg:npm/lodash@<4.17.21", "pkg:npm/lodash@4.17.21"), pmNoMatch)
  assertEq(matches("pkg:npm/lodash@>=4.0,<4.17.21", "pkg:npm/lodash@3.10.1"), pmNoMatch)
  assertEq(matches("pkg:npm/lodash@>=4.0,<4.17.21", "pkg:npm/lodash@4.1.0"), pmMatch)
  assertEq(matches("pkg:npm/lodash@==4.1", "pkg:npm/lodash@4.1.0"), pmMatch)
  assertEq(matches("pkg:npm/lodash@!=4.1.0", "pkg:npm/lodash@4.1.0"), pmNoMatch)
  assertEq(matches("pkg:golang/github.com/google/uuid@>=1.5", "pkg:golang/github.com/google/uuid@v1.6.0"), pmMatch)
  # only versions chalk can order are compared
  assertEq(matches("pkg:deb/debian/libc6@<2.37", "pkg:deb/debian/libc6@1:2.36-9"), pmUnknown)
  assertEq(matches("pkg:npm/lodash@<4.17.21", "pkg:npm/lodash"), pmUnknown)
  assertEq(matches("pkg:npm/lodash", ""), pmNoMatch)

proc testQuestionGlobsAndQualifiers() =
  assertEq(matches("pkg:npm/lib?", "pkg:npm/libx@1.0.0"), pmMatch)
  assertEq(matches("pkg:npm/lib?", "pkg:npm/lib@1.0.0"), pmNoMatch)
  assertEq(matches("pkg:npm/x@1.?", "pkg:npm/x@1.2"), pmMatch)
  assertEq(matches("pkg:npm/x@1.?", "pkg:npm/x@1.22"), pmNoMatch)
  assertEq(matches("pkg:npm/lib??@1.?", "pkg:npm/libxy@1.2"), pmMatch)
  assertEq(matches("pkg:npm/lib%3F@1.%3F", "pkg:npm/libx@1.2"), pmMatch)
  assertEq(matches("pkg:npm/lib?@1.?arch=amd64&os=linux", "pkg:npm/libx@1."), pmMatch)
  assertEq(matches("pkg:npm/lib?@1.??arch=amd64", "pkg:npm/libx@1.2?arch=arm64"), pmMatch)
  assertEq(matches("pkg:npm/x@1.2?arch=amd64#sub", "pkg:npm/x@1.2?arch=arm64"), pmMatch)
  # Percent-encoded @ belongs to the name; + is not a space.
  assertEq(matches("pkg:generic/a%40b@1+meta", "pkg:generic/a%40b@1+meta"), pmMatch)
  let sbom = PolicySboms(sboms: @[Sbom(packages: @[
    SbomPackage(name: "libx", purl: "pkg:npm/libx@1.0.0")])])
  let denied = PackagesConfig(denied: @[("purl", "pkg:npm/lib?")]).checkPackages(sbom)
  assertEq(denied.len, 1)
  assertEq(denied[0].kind, "violation")
  let allowed = PackagesConfig(allowed: @[("purl", "pkg:npm/lib?")]).checkPackages(sbom)
  assertEq(allowed.len, 0)

proc fixtureSboms(): PolicySboms =
  PolicySboms(sboms: @[parseSbom(parseJson(readFile(fixture)))])

proc subjects(findings: seq[PolicyFinding], kind = "violation"): seq[string] =
  for f in findings:
    if f.kind == kind:
      result.add(f.subject)

proc testCheck() =
  var settings = PackagesConfig(
    denied: @[("purl", "pkg:npm/event-stream@3.3.6"),
              ("purl", "pkg:pypi/*colourama*"),
              ("purl", "pkg:npm/lodash@<4.17.21")],
    message: "See https://example.com/packages",
  )
  var findings = settings.checkPackages(fixtureSboms())
  assertEq(findings.subjects(), @["pkg:pypi/colourama@0.1.0",
                                  "pkg:npm/event-stream@3.3.6",
                                  "pkg:npm/lodash@4.17.20"])
  assertEq(findings[0].rule, "packages")
  assertEq(findings[0].location, "/py/requirements.txt")
  assertEq(findings[0].image, "")
  doAssert findings[0].reason.startsWith("package is denied (pkg:pypi/*colourama*)")
  doAssert findings[0].reason.endsWith(". See https://example.com/packages")

  # a range that cannot be compared is an error, not a pass
  settings = PackagesConfig(denied: @[("purl", "pkg:deb/debian/libc6@<3")])
  findings = settings.checkPackages(fixtureSboms())
  assertEq(findings.subjects("error"), @["pkg:deb/debian/libc6@1:2.36-9?arch=amd64"])

  # languages are reported once per language
  settings = PackagesConfig(allowedLanguages: @["Go", "javascript"])
  findings = settings.checkPackages(fixtureSboms())
  assertEq(len(findings), 1)
  assertEq(findings[0].subject, "python")
  assertEq(findings[0].reason, "language is not allowed (3 packages: pkg:pypi/colourama@0.1.0, " &
                               "pkg:pypi/django-rest@1.0, pkg:pypi/requests@2.31.0)")
  settings = PackagesConfig(deniedLanguages: @["javascript"])
  findings = settings.checkPackages(fixtureSboms())
  assertEq(findings.subjects(), @["javascript"])
  doAssert "5 packages" in findings[0].reason and "+2 more" in findings[0].reason

  # an allowlist covers every package with a purl
  settings = PackagesConfig(allowedLanguages: @["go", "javascript"],
                            allowed: @[("purl", "pkg:npm/*"), ("purl", "pkg:golang/github.com/google/*")])
  findings = settings.checkPackages(fixtureSboms())
  assertEq(findings.subjects(), @["python", "pkg:deb/debian/libc6@1:2.36-9?arch=amd64"])

  # configuration problems are evaluation errors
  settings = PackagesConfig(denied: @[("regex", ".*"), ("purl", "lodash")],
                            allowed: @[("glob", "x")])
  findings = settings.checkPackages(fixtureSboms())
  assertEq(len(findings), 3)
  for f in findings:
    assertEq(f.kind, "error")

  # duplicates are reported once and findings are capped
  var many = Sbom(source: "/src")
  for i in 0 ..< maxPackageFindings + 5:
    many.packages.add(SbomPackage(purl: "pkg:npm/p" & $i & "@1.0.0"))
    many.packages.add(SbomPackage(purl: "pkg:npm/p" & $i & "@1.0.0"))
  settings = PackagesConfig(denied: @[("purl", "pkg:npm/*")])
  findings = settings.checkPackages(PolicySboms(sboms: @[many]))
  assertEq(len(findings), maxPackageFindings + 1)
  doAssert findings[^1].reason == "5 more packages not listed"

  findings = PackagesConfig().checkPackages(
    PolicySboms(errors: @[newSubjectFinding("packages", "error", "", "no SBOM")]))
  assertEq(findings.subjects("error"), @[""])
  doAssert not PackagesConfig(message: "x").hasChecks()

proc testConfig() =
  setPolicyJson(readFile(configFixture))
  let policy = policyConfigs()[0]
  doAssert policy.configError == "", policy.configError
  selectPolicy(policy)
  let settings = loadPackagesConfig().get()
  assertEq(settings.denied, @[("purl", "pkg:npm/event-stream@3.3.6"),
                              ("purl", "pkg:pypi/*colourama*")])
  assertEq(settings.allowedLanguages, @["go", "javascript"])
  assertEq(settings.deniedLanguages, @["python"])
  assertEq(settings.allowed, @[("purl", "pkg:npm/*")])
  assertEq(settings.message, "Use approved packages")

  setPolicyJson("""{"mode": "audit", "packages": {"enabled": false, "denied": [["purl", "x"]]}}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadPackagesConfig().isNone()

  for (text, reason) in [
    ("""{"packages": {"enabeld": true}}""", "unknown field policy.packages.enabeld"),
    ("""{"packages": {"denied": [["purl"]]}}""", "[kind, value] string pairs"),
    ("""{"packages": {"allowed_languages": [1]}}""", "policy.packages.allowed_languages entries must be strings"),
    ("""{"packages": {"denied_languages": "go"}}""", "policy.packages.denied_languages must be a array"),
    ("""{"packages": []}""", "policy.packages must be an object"),
  ]:
    try:
      discard parsePolicyJson(text)
      doAssert false, "accepted: " & text
    except ValueError:
      doAssert reason in getCurrentExceptionMsg(), getCurrentExceptionMsg()
  setPolicyJson("")

proc testEngine() =
  # the rule only produces an SBOM when it has something to check
  clearPolicyToolCache()
  var scans = 0
  policyToolRunner = proc(request: ToolRequest, dir: string): seq[ToolOutput] =
    inc(scans)
    @[ToolOutput(tool: "syft", root: dir, value: parseJson(readFile(fixture)))]
  setPolicyJson("""{"policies": [
    {"id": "noop", "mode": "audit", "packages": {"enabled": true}},
    {"id": "deny", "mode": "enforce", "packages": {"enabled": true, "denied": [["purl", "pkg:npm/lodash"]]}},
    {"id": "langs", "mode": "audit", "packages": {"enabled": true, "allowed_languages": ["go"]}}
  ]}""")
  loadPackagesRule()
  var rules: seq[PolicyRule]
  for rule in policyRules():
    if rule.name == "packages":
      rules.add(rule)
  policyOutcome = nil
  let build = ChalkDict()
  build["command"] = pack("build")
  var blocked = false
  try:
    evaluatePolicies(build, proc(): PolicyInput =
      PolicyInput(command: "build", contextDirs: @["/src"], host: ChalkDict()), rules)
  except PolicyViolation:
    blocked = true
  doAssert blocked
  assertEq(scans, 1)
  doAssert policyOutcome != nil
  assertEq(policyOutcome.policies[0].result, "pass")
  assertEq(policyOutcome.policies[1].result, "blocked")
  assertEq(policyOutcome.policies[2].result, "violation")
  assertEq(policyOutcome.findings[0].subject, "pkg:npm/lodash@4.17.20")
  assertEq(policyOutcome.findings[0].location, "web/package-lock.json")
  assertEq(policyOutcome.findings[1].subject, "javascript")
  setPolicyJson("")
  clearPolicyToolCache()

proc main() =
  testPurls()
  testPatterns()
  testQuestionGlobsAndQualifiers()
  testCheck()
  testConfig()
  testEngine()

main()
