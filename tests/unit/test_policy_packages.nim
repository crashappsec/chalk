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

proc fixtureSboms(): PolicySboms =
  PolicySboms(sboms: @[parseSbom(parseJson(readFile(fixture)))])

proc subjects(findings: seq[PolicyFinding], kind = "violation"): seq[string] =
  for f in findings:
    if f.kind == kind:
      result.add(f.subject)

proc testPatterns() =
  # other range syntaxes would be globs matching no version
  for bad in ["pkg:npm/lodash@^4.17.0", "pkg:npm/lodash@~4.17.0", "pkg:pypi/x@~=1.0",
              "pkg:npm/x@4.x", "pkg:maven/a/b@[1.0,2.0)", "pkg:npm/x@1 - 2",
              "pkg:npm/x@1 || 2", "pkg:npm/lodash@<1.0.post1"]:
    try:
      discard parsePackagePattern(bad)
      doAssert false, "accepted " & bad
    except ValueError:
      discard
  for good in ["pkg:npm/lodash@4.*", "pkg:npm/lodash@>=4,<5", "pkg:npm/lodash", "pkg:npm/x@1.?"]:
    discard parsePackagePattern(good)
  let findings = PackagesConfig(denied: @[("purl", "pkg:npm/lodash@^4.17.0")]).checkPackages(
    PolicySboms(sboms: @[Sbom(packages: @[SbomPackage(purl: "pkg:npm/lodash@4.17.20")])]))
  assertEq(findings.len, 1)
  assertEq(findings[0].kind, "error")
  doAssert "unsupported version range" in findings[0].reason, findings[0].reason

proc testLanguages() =
  assertEq(normalizeLanguage("Golang"), "go")
  assertEq(normalizeLanguage(" node "), "javascript")
  assertEq(normalizeLanguage("TypeScript"), "javascript")
  assertEq(normalizeLanguage("C#"), "dotnet")
  assertEq(normalizeLanguage("csharp"), "dotnet")
  assertEq(normalizeLanguage("py"), "python")
  assertEq(normalizeLanguage("rb"), "ruby")
  assertEq(normalizeLanguage("cpp"), "c++")
  assertEq(normalizeLanguage("R"), "r")
  for bad in ["", "cobol", "pyhton"]:
    try:
      discard normalizeLanguage(bad)
      doAssert false, "accepted " & bad
    except ValueError:
      doAssert "unknown language" in getCurrentExceptionMsg()

  let sbom = PolicySboms(sboms: @[Sbom(packages: @[
    SbomPackage(purl: "pkg:golang/a@1.0.0", purlType: "golang", language: "go"),
    SbomPackage(purl: "pkg:conan/zlib@1.3", purlType: "conan", language: "cpp"),
    SbomPackage(purl: "pkg:cocoapods/Alamofire@5.0", purlType: "cocoapods"),
    SbomPackage(purl: "pkg:deb/debian/libc6@2.36", purlType: "deb"),
    SbomPackage(purl: "pkg:github/actions/checkout@v4", purlType: "github"),
    SbomPackage(purl: "pkg:hex/phoenix@1.7.0", purlType: "hex"),
    SbomPackage(purl: "pkg:generic/thing@1", purlType: "generic"),
    SbomPackage(name: "mystery", version: "2", location: "/vendor/x"),
    SbomPackage(name: "typed", language: "ruby"),
  ])])
  # the SBOM's `cpp` is syft's `c++`, and cocoapods is swift
  var findings = PackagesConfig(allowedLanguages: @["golang", "c++", "swift", "ruby"]).checkPackages(sbom)
  assertEq(findings.subjects(), newSeq[string]())
  # OS and CI packages are not dependencies in any language; packages whose
  # language is unknown cannot be vouched for by an allowlist
  assertEq(findings.subjects("error"), @[""])
  assertEq(findings[0].reason,
           "could not determine the language of 3 packages: pkg:hex/phoenix@1.7.0, " &
           "pkg:generic/thing@1, mystery@2 (/vendor/x), so allowed_languages cannot be " &
           "checked for them")
  findings = PackagesConfig(allowedLanguages: @["go"]).checkPackages(sbom)
  assertEq(findings.subjects(), @["c++", "swift", "ruby"])
  assertEq(findings.subjects("error"), @[""])
  # a denylist only reports what it can identify
  findings = PackagesConfig(deniedLanguages: @["ruby"]).checkPackages(sbom)
  assertEq(findings.subjects(), @["ruby"])
  assertEq(findings.subjects("error"), newSeq[string]())
  findings = PackagesConfig(denied: @[("purl", "pkg:*/mystery")]).checkPackages(sbom)
  assertEq(len(findings), 0)
  # without a purl a package cannot match an allowlist
  findings = PackagesConfig(allowed: @[("purl", "pkg:*/*")]).checkPackages(sbom)
  assertEq(findings.subjects(), newSeq[string]())
  assertEq(findings.subjects("error"), @[""])
  doAssert findings[0].reason.startsWith("could not determine the package URL of 2 packages: " &
                                         "mystery@2 (/vendor/x), typed"), findings[0].reason
  # unknown languages configured without validation are evaluation errors
  findings = PackagesConfig(deniedLanguages: @["cobol"]).checkPackages(sbom)
  assertEq(findings.subjects("error"), @[""])

proc testQuestionGlobs() =
  let sbom = PolicySboms(sboms: @[Sbom(packages: @[
    SbomPackage(name: "libx", purl: "pkg:npm/libx@1.0.0")])])
  let denied = PackagesConfig(denied: @[("purl", "pkg:npm/lib?")]).checkPackages(sbom)
  assertEq(denied.len, 1)
  assertEq(denied[0].kind, "violation")
  let allowed = PackagesConfig(allowed: @[("purl", "pkg:npm/lib?")]).checkPackages(sbom)
  assertEq(allowed.len, 0)

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

  # an allowlist covers every package; OS packages have no language
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

  setPolicyJson("""{"mode": "audit", "packages": {"enabled": false}}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadPackagesConfig().isNone()

  setPolicyJson("""{"packages": {"enabled": true, "allowed_languages": ["Golang", "node", "js"],
                                 "denied_languages": ["C#"]}}""")
  selectPolicy(policyConfigs()[0])
  let aliased = loadPackagesConfig().get()
  assertEq(aliased.allowedLanguages, @["go", "javascript"])
  assertEq(aliased.deniedLanguages, @["dotnet"])

  for (text, reason) in [
    ("""{"packages": {"enabeld": true}}""", "unknown field policy.packages.enabeld"),
    ("""{"packages": {"denied": [["purl"]]}}""", "[kind, value] string pairs"),
    ("""{"packages": {"allowed_languages": [1]}}""", "policy.packages.allowed_languages entries must be strings"),
    ("""{"packages": {"denied_languages": "go"}}""", "policy.packages.denied_languages must be a array"),
    ("""{"packages": []}""", "policy.packages must be an object"),
    ("""{"packages": {"allowed_languages": ["go", "cobol"]}}""",
     "policy.packages.allowed_languages: unknown language \"cobol\""),
    ("""{"packages": {"denied_languages": ["pyhton"]}}""",
     "policy.packages.denied_languages: unknown language \"pyhton\""),
    ("""{"packages": {"denied": [["regex", ".*"]]}}""",
     "policy.packages.denied: unsupported entry kind \"regex\""),
    ("""{"packages": {"allowed": [["purl", "lodash"]]}}""",
     "policy.packages.allowed: invalid entry \"lodash\""),
    ("""{"packages": {"denied": [["purl", "pkg:npm/lodash@^4.17.0"]]}}""",
     "unsupported version range"),
  ]:
    # an unusable policy is kept with its error, see parsePolicyJson
    var message = ""
    try:
      let configs = parsePolicyJson(text)
      doAssert configs.len == 1, "accepted: " & text
      message = configs[0].configError
    except ValueError:
      message = getCurrentExceptionMsg()
    doAssert reason in message, text & ": " & message
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
  # without it the engine collects no build contexts and nothing is scanned
  doAssert rules[0].requiresContext
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
  # without a message the step summary must not suggest an allowed image
  for p in policyOutcome.policies:
    for h in p.hints:
      assertEq(h.rule, "")
  setPolicyJson("""{"mode": "audit", "packages": {"enabled": true, "allowed_languages": ["go"],
                                                  "message": "Ask #deps"}}""")
  policyOutcome = nil
  evaluatePolicies(build, proc(): PolicyInput =
    PolicyInput(command: "build", contextDirs: @["/src"], host: ChalkDict()), rules)
  assertEq(policyOutcome.policies[0].hints[0].message, "Ask #deps")
  assertEq(policyOutcome.policies[0].hints[0].allowed, @["go"])
  setPolicyJson("")
  clearPolicyToolCache()

proc main() =
  testPatterns()
  testLanguages()
  testQuestionGlobs()
  testCheck()
  testConfig()
  testEngine()

main()
