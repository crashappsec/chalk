import std/[json, os, strutils]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/engine
import ../../src/policy/rules
import ../../src/policy/rules/secrets

const
  fixture = currentSourcePath().parentDir() / "fixtures" / "trufflehog_filesystem.jsonl"
  # stands in for every secret value in the fixture
  rawValue = "FAKE-RAW-VALUE"

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc settings(json: string): SecretsConfig =
  setPolicyJson(json)
  selectPolicy(policyConfigs()[0])
  loadSecretsConfig().get()

proc rejects(json, reason: string) =
  setPolicyJson(json)
  let policy = policyConfigs()[0]
  doAssert reason in policy.configError, json & ": " & policy.configError

proc locations(findings: seq[PolicyFinding]): seq[string] =
  for f in findings:
    result.add(f.kind & " " & f.subject & " " & f.location & " " & f.severity)

proc assertNoSecret(findings: seq[PolicyFinding]) =
  for f in findings:
    for field in [f.subject, f.location, f.reason, f.severity, f.image]:
      doAssert rawValue notin field, field

proc testParse() =
  let results = parseTrufflehogOutput("trufflehog 3.99 starting\n" & readFile(fixture))
  assertEq(len(results), 8)
  assertEq(results[^1].commit, "abc")
  let first = results[0]
  assertEq(first.detector, "Github")
  assertEq(first.file, "/ctx/app/.env")
  assertEq(first.line, 1)
  assertEq(first.severity(), "verified")
  assertEq(first.rotationGuide, "https://howtorotate.com/docs/tutorials/github/")
  assertEq(results[1].severity(), "unverified")
  assertEq(results[2].severity(), "unknown")
  assertEq(parseTrufflehogOutput("").len, 0)
  try:
    discard parseTrufflehogOutput("{\"Raw\": \"" & rawValue & "\"")
    doAssert false
  except ValueError:
    doAssert rawValue notin getCurrentExceptionMsg()

proc testValidation() =
  rejects("""{"secrets": {"enabeld": true}}""", "unknown field policy.secrets.enabeld")
  rejects("""{"secrets": {"verify": "no"}}""", "policy.secrets.verify must be a boolean")
  rejects("""{"secrets": {"detectors": [1]}}""", "policy.secrets.detectors entries must be strings")
  rejects("""{"secrets": {"exclude_paths": ["!keep"]}}""", "cannot start with '!'")
  rejects("""{"secrets": {"exclude_paths": ["[a"]}}""", "invalid pattern")
  rejects("""{"secrets": {"verify": false}}""", "verify = false requires policy.secrets.verified_only = false")
  rejects("""{"secrets": []}""", "policy.secrets must be an object")
  rejects("""{"secrets": {"check_push": 1}}""", "policy.secrets.check_push must be a boolean")
  setPolicyJson("""{"secrets": {"verify": false, "verified_only": false}}""")
  assertEq(policyConfigs()[0].configError, "")

proc testDefaults() =
  setPolicyJson("""{"mode": "audit"}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadSecretsConfig().isNone()
  let s = settings("""{"mode": "audit", "secrets": {"enabled": true}}""")
  doAssert s.verify and s.verifiedOnly
  doAssert s.detectors.len == 0 and s.excludePaths.len == 0

proc testCheck() =
  let results = parseTrufflehogOutput(readFile(fixture))
  var s = settings("""{"secrets": {"enabled": true, "message": "See go/secrets"}}""")
  var findings = s.check(results, "/ctx", @["node_modules"])
  findings.assertNoSecret()
  # unverified ones are ignored, unknown ones are left to on_error,
  # duplicates and .dockerignore'd files are dropped
  assertEq(findings.locations(), @[
    "violation Github app/.env:1 verified",
    "error AWS app/deploy.sh:3 unknown",
    "violation Stripe tests/fixtures/keys.txt:2 verified",
  ])
  assertEq(findings[0].rule, "secrets")
  assertEq(findings[0].reason,
           "verified Github secret in the build context. " &
           "Rotate it: https://howtorotate.com/docs/tutorials/github/. See go/secrets")
  assertEq(findings[1].reason, "AWS secret in the build context could not be verified. See go/secrets")

  s = settings("""{"secrets": {"enabled": true, "verified_only": false,
                   "ignore_detectors": ["uri"], "exclude_paths": ["tests"]}}""")
  findings = s.check(results, "/ctx", @[])
  findings.assertNoSecret()
  assertEq(findings.locations(), @[
    "violation Github app/.env:1 verified",
    "violation Slack app/config.yml:7 unverified",
    "violation AWS app/deploy.sh:3 unknown",
    "violation Github node_modules/pkg/index.js:9 verified",
  ])
  assertEq(findings[1].reason,
           "unverified Slack secret in the build context (may be a false positive)")

  s = settings("""{"secrets": {"enabled": true, "detectors": ["GITHUB"],
                   "exclude_paths": ["**/index.js"]}}""")
  assertEq(s.check(results, "/ctx", @[]).locations(), @[
    "violation Github app/.env:1 verified",
  ])
  # other context directories are reported with absolute paths
  assertEq(s.check(results, "/ctx/app", @[], relative = false).locations(), @[
    "violation Github /ctx/app/.env:1 verified",
  ])
  # `*` does not cross directories, as in .dockerignore
  s = settings("""{"secrets": {"enabled": true, "exclude_paths": ["*.env", "app/*.env"]}}""")
  assertEq(s.check(results, "/ctx", @["*/index.js"]).locations(), @[
    "error AWS app/deploy.sh:3 unknown",
    "violation Stripe tests/fixtures/keys.txt:2 verified",
    "violation Github node_modules/pkg/index.js:9 verified",
  ])

proc testCap() =
  var findings: seq[PolicyFinding]
  for i in 0 ..< 105:
    findings.add(newSubjectFinding("secrets", (if i < 3: "error" else: "violation"),
                                   "Github", "x", location = "f:" & $i))
  let capped = findings.capFindings()
  assertEq(len(capped), 101)
  assertEq(capped[0].kind, "violation")
  # 2 of the 5 left out are violations
  assertEq(capped[^1].kind, "violation")
  assertEq(capped[^1].reason, "5 more secret(s) in the build context not listed")
  assertEq(findings[0 ..< 10].capFindings().len, 10)

proc testDockerignore() =
  let dir = getTempDir() / "chalk-test-policy-secrets"
  createDir(dir)
  defer: removeDir(dir)
  doAssert readDockerignore(dir).len == 0
  writeFile(dir / ".dockerignore", "# comment\n\n/node_modules\n.env\n!/keep.env\n")
  assertEq(readDockerignore(dir), @["node_modules", ".env", "!keep.env"])
  # the Dockerfile's own ignore file replaces the context's
  let dockerfile = dir / "build" / "app.Dockerfile"
  createDir(dir / "build")
  assertEq(readDockerignore(dir, dockerfile), @["node_modules", ".env", "!keep.env"])
  writeFile(dockerfile & ".dockerignore", "secrets/\n")
  assertEq(readDockerignore(dir, dockerfile), @["secrets/"])

proc mark(scanner: JsonNode): ChalkDict =
  result = ChalkDict()
  result["SECRET_SCANNER"] = nimJsonToBox(scanner)

proc testMark() =
  let item = %*{
    "SourceMetadata": {"Data": {"Git": {"commit": "0123456789abcdef", "file": "app/.env", "line": 4}}},
    "DetectorName": "Github", "Verified": true, "RawHash": "ab", "Redacted": "ghp_",
  }
  let fsItem = %*{
    "SourceMetadata": {"Data": {"Filesystem": {"file": "/src/tests/key.txt", "line": 1}}},
    "DetectorName": "Slack", "Verified": false,
  }
  doAssert markSecretResults(ChalkDict()).len == 0
  let results = markSecretResults(mark(%*{"trufflehog": [item, fsItem]}))
  assertEq(len(results), 2)
  # canonicalized marks key results by hash
  assertEq(markSecretResults(mark(%*{"trufflehog": {"h1": item}})).len, 1)
  var s = settings("""{"secrets": {"enabled": true, "verified_only": false,
                   "exclude_paths": ["tests"]}}""")
  let findings = s.checkMark(results)
  assertEq(findings.locations(), @[
    "violation Github app/.env:4 verified",
    "violation Slack /src/tests/key.txt:1 unverified",
  ])
  assertEq(findings[0].reason,
           "verified Github secret recorded in the image's chalk mark (commit 0123456789ab)")
  s = settings("""{"secrets": {"enabled": true, "exclude_paths": ["app"]}}""")
  assertEq(s.checkMark(results).len, 0)

proc testRule() =
  setPolicyJson("""{"mode": "enforce", "secrets": {"enabled": true}}""")
  let policy = policyConfigs()[0]
  selectPolicy(policy)
  loadPolicyRules()
  var rule: PolicyRule
  for r in policyRules():
    if r.name == "secrets":
      rule = r
  doAssert rule != nil and rule.checkInput != nil
  doAssert rule.load()
  doAssert rule.hint().rule == ""
  let secretMark = mark(%*{"trufflehog": [{
    "SourceMetadata": {"Data": {"Git": {"file": "a.txt", "line": 1}}},
    "DetectorName": "AWS", "Verified": true}]})
  # push is only checked with check_push
  assertEq(rule.checkInput(PolicyInput(command: "push", pushMarks: @[secretMark])).len, 0)
  let findings = rule.checkInput(PolicyInput(command: "build"))
  assertEq(findings.locations(), @["error build context  "])
  let result = evaluatePolicy(policy, @[rule], PolicyInput(command: "build"))
  # an evaluation error only blocks with on_error = "block"
  assertEq(result.result, "error")
  setPolicyJson("""{"mode": "enforce", "secrets": {"enabled": true, "check_push": true}}""")
  selectPolicy(policyConfigs()[0])
  doAssert rule.load()
  assertEq(rule.checkInput(PolicyInput(command: "push", pushMarks: @[secretMark, ChalkDict()])).locations(),
           @["violation AWS a.txt:1 verified"])
  setPolicyJson("""{"mode": "enforce", "secrets": {"enabled": false}}""")
  selectPolicy(policyConfigs()[0])
  doAssert not rule.load()

proc main() =
  testParse()
  testValidation()
  testDefaults()
  testCheck()
  testCap()
  testDockerignore()
  testMark()
  testRule()

main()
