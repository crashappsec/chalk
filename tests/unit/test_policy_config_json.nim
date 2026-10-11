import std/[json, os, strutils]
import ../../src/types
import ../../src/policy/engine
import ../../src/policy/rules
import ../../src/policy/rules/golden_images
import ../../src/docker/ids

const
  fixture      = currentSourcePath().parentDir() / "fixtures" / "policy_config.json"
  multiFixture = currentSourcePath().parentDir() / "fixtures" / "policy_config_multi.json"

proc policy(): PolicyConfig =
  result = policyConfigs()[0]
  selectPolicy(result)

proc rejects(text, reason: string) =
  ## the document is unusable as a whole, or as its only policy
  var message = ""
  try:
    let configs = parsePolicyJson(text)
    doAssert configs.len == 1, "accepted: " & text
    message = configs[0].configError
  except ValueError:
    message = getCurrentExceptionMsg()
  doAssert message != "", "accepted: " & text
  doAssert reason in message, message

proc testValidation() =
  rejects("{", "not valid JSON")
  rejects("[]", "must be a JSON object")
  rejects("""{"mode": "block"}""", "policy.mode must be one of")
  rejects("""{"mode": true}""", "policy.mode must be a string, got boolean")
  rejects("""{"sink_config": {}}""", "unknown field policy.sink_config")
  rejects("""{"custom_check": "f"}""", "unknown field policy.custom_check")
  rejects("""{"golden_images": {"enabeld": true}}""", "unknown field policy.golden_images.enabeld")
  rejects("""{"golden_images": {"allowed": [["glob"]]}}""", "[kind, value] string pairs")
  rejects("""{"golden_images": {"allowed": [{"kind": "glob", "value": "x"}]}}""", "[kind, value] string pairs")
  rejects("""{"policies": {}}""", "policy.policies must be an array, got object")
  rejects("""{"policies": [], "mode": "audit"}""", "cannot be combined with other fields")
  discard parsePolicyJson("{}")
  doAssert parsePolicyJson("""{"policies": []}""").len == 0

proc testFixture() =
  setPolicyJson(readFile(fixture))
  doAssert policyConfigs().len == 1
  let settings = policy()
  doAssert settings.id == "golden-images@3"
  doAssert settings.mode == "enforce" and settings.onError == "allow"
  doAssert settings.configError == ""
  let golden = loadGoldenImagesConfig().get()
  doAssert golden.checkCopyFrom
  doAssert golden.allowed == @[("glob", "docker.io/library/alpine:*"),
                               ("glob", "cgr.dev/chainguard/*")]
  doAssert golden.message == "Use an approved golden image"

proc testDefaults() =
  setPolicyJson("""{"mode": "audit"}""")
  doAssert policy().onError == "allow"
  doAssert loadGoldenImagesConfig().isNone()
  setPolicyJson("""{"mode": "audit", "golden_images": {"enabled": true}}""")
  discard policy()
  let golden = loadGoldenImagesConfig().get()
  doAssert golden.checkCopyFrom and golden.allowed.len == 0

proc build(): ChalkDict =
  result = ChalkDict()
  result["command"] = pack("build")

proc testEnforcedFromJson() =
  setPolicyJson(readFile(fixture))
  policyOutcome = nil
  let settings = policy()
  let subject = PolicySubject(image: parseImage("python:3.12-slim"), raw: "python:3.12-slim",
                              source: "from")
  let golden = loadGoldenImagesConfig().get()
  # the con4m-backed custom_check rule cannot load without a con4m runtime
  let rule = PolicyRule(name: "golden_images", requiresAllSubjects: true,
                        load: proc(): bool = true,
                        check: proc(subjects: seq[PolicySubject]): seq[PolicyFinding] =
                          golden.check(subjects))
  var blocked = false
  try:
    evaluatePolicies(settings, @[rule], PolicyInput(subjects: @[subject]), build())
  except PolicyViolation:
    blocked = true
  doAssert blocked
  doAssert policyOutcome.id == "golden-images@3"
  doAssert policyOutcome.asChalkDict().hasKey("_POLICY_ID")
  doAssert policyOutcome.findings[0].policyId == "golden-images@3"

proc evaluateInvalid(text: string): tuple[blocked, collected: bool] =
  setPolicyJson(text)
  policyOutcome = nil
  var collected = false
  try:
    evaluatePolicies(build(), proc(): PolicyInput =
      collected = true
      PolicyInput())
  except PolicyViolation:
    result.blocked = true
  result.collected = collected

proc testInvalidConfigHonorsDeclaredMode() =
  let broken = """"golden_images": {"enabled": 1}"""
  # a broken enforced policy fails closed with on_error=block
  var (blocked, collected) = evaluateInvalid(
    """{"id": "p", "mode": "enforce", "on_error": "block", """ & broken & "}")
  doAssert blocked and not collected
  doAssert policyOutcome.result == "blocked"
  doAssert policyOutcome.findings.len == 1
  doAssert policyOutcome.findings[0].rule == "config"
  doAssert policyOutcome.findings[0].kind == "error"
  doAssert policyOutcome.findings[0].policyId == "p"
  doAssert "policy.golden_images.enabled" in policyOutcome.findings[0].reason

  (blocked, collected) = evaluateInvalid(
    """{"mode": "enforce", "on_error": "allow", """ & broken & "}")
  doAssert not blocked and not collected
  doAssert policyOutcome.result == "error"
  doAssert not policyOutcome.asChalkDict().hasKey("_POLICY_ID")

  # a broken policy in mode off stays off
  setPolicyJson("""{"mode": "off", "on_error": "block", """ & broken & "}")
  doAssert policyConfigs()[0].configError != ""
  doAssert not policyEnabled()
  (blocked, collected) = evaluateInvalid(
    """{"mode": "off", "on_error": "block", """ & broken & "}")
  doAssert not blocked and policyOutcome == nil

  # nothing (validly) declared: reported, never blocks
  for doc in ["{", "[]", """{"policies": {}}""",
              """{"on_error": "block", """ & broken & "}",
              """{"mode": "enforced", "on_error": "block", """ & broken & "}"]:
    (blocked, collected) = evaluateInvalid(doc)
    doAssert not blocked and not collected, doc
    doAssert policyOutcome.result == "error", doc
    doAssert policyOutcome.policies[0].mode == "audit", doc
    doAssert policyOutcome.findings[0].rule == "config", doc

  # an invalid on_error is not declared either
  (blocked, collected) = evaluateInvalid("""{"mode": "enforce", "on_error": true, """ & broken & "}")
  doAssert not blocked and policyOutcome.result == "error"
  doAssert policyOutcome.policies[0].mode == "enforce"
  doAssert policyOutcome.policies[0].onError == "allow"

  # a valid enforce_repos is kept, an invalid one is not
  var configs = parsePolicyJson("""{"mode": "off", "enforce_repos": [["glob", "github.com/a/*"]], """ &
                                broken & "}")
  doAssert configs[0].mode == "off" and configs[0].configError != ""
  doAssert configs[0].enforceRepos == @[("glob", "github.com/a/*")]
  doAssert configs[0].mayBeEvaluated()
  configs = parsePolicyJson("""{"mode": "enforce", "enforce_repos": [["glob"]]}""")
  doAssert configs[0].mode == "enforce" and configs[0].enforceRepos.len == 0
  setPolicyJson("")

proc goldenImagesRule(): PolicyRule =
  # the registered rule, reading the selected policy's settings; custom_check
  # is skipped as it cannot load without a con4m runtime
  loadPolicyRules()
  for rule in policyRules():
    if rule.name == "golden_images":
      return rule
  doAssert false, "golden_images is not registered"

proc subject(image: string): PolicySubject =
  PolicySubject(image: parseImage(image), raw: image, source: "from")

proc evaluateJson(text: string, subjects: seq[PolicySubject],
                  errors: seq[PolicyFinding] = @[]): tuple[blocked: bool, collected: int] =
  setPolicyJson(text)
  policyOutcome = nil
  var collected = 0
  let collect = proc(): PolicyInput =
    inc(collected)
    PolicyInput(subjects: subjects, errors: errors)
  try:
    evaluatePolicies(build(), collect, @[goldenImagesRule()])
  except PolicyViolation:
    result.blocked = true
  result.collected = collected

proc results(): seq[(string, string)] =
  for r in policyOutcome.policies:
    result.add((r.id, r.result))

proc testMultiFixture() =
  setPolicyJson(readFile(multiFixture))
  doAssert policyJsonIsList()
  let policies = policyConfigs()
  doAssert policies.len == 2
  doAssert policies[0].id == "golden-images@3" and policies[0].mode == "enforce"
  doAssert policies[1].id == "chainguard-only@1" and policies[1].mode == "audit"
  doAssert policies[1].onError == "block"
  for p in policies:
    doAssert p.configError == ""
  selectPolicy(policies[1])
  let golden = loadGoldenImagesConfig().get()
  doAssert not golden.checkCopyFrom
  doAssert golden.allowed == @[("glob", "cgr.dev/chainguard/*")]

proc testSingleObjectIsNotAList() =
  setPolicyJson(readFile(fixture))
  doAssert not policyJsonIsList()
  # a one-entry list needs no id
  setPolicyJson("""{"policies": [{"mode": "audit"}]}""")
  doAssert policyJsonIsList()
  doAssert policyConfigs().len == 1 and policyConfigs()[0].configError == ""

proc testEmptyListIsNoPolicy() =
  setPolicyJson("""{"policies": []}""")
  doAssert not policyEnabled()
  let (blocked, collected) = evaluateJson("""{"policies": []}""", @[subject("busybox")])
  doAssert not blocked and collected == 0
  doAssert policyOutcome == nil

proc testIdsMustBeUnique() =
  let policies = parsePolicyJson("""{"policies": [
    {"id": "a", "mode": "enforce"},
    {"id": "a", "mode": "audit"},
    {"mode": "audit"},
    {"id": "b", "mode": "enforce"}
  ]}""")
  doAssert policies.len == 4
  doAssert "policy.policies[0].id \"a\" is not unique" in policies[0].configError
  doAssert "policy.policies[1].id \"a\" is not unique" in policies[1].configError
  doAssert "policy.policies[2].id must be set" in policies[2].configError
  doAssert policies[3].configError == "" and policies[3].id == "b"
  # invalid entries keep the mode and on_error they declare
  doAssert policies[0].mode == "enforce" and policies[0].onError == "allow"
  doAssert policies[1].mode == "audit"

proc testAuditAndEnforceDecideIndependently() =
  let multi = readFile(multiFixture)
  # allowed by the enforced policy, only violates the audited one
  var (blocked, collected) = evaluateJson(multi, @[subject("alpine:3.20")])
  doAssert not blocked and collected == 1
  doAssert policyOutcome.result == "violation" and policyOutcome.mode == "enforce"
  doAssert results() == @[("golden-images@3", "pass"), ("chainguard-only@1", "violation")]
  doAssert policyOutcome.findings.len == 1
  doAssert policyOutcome.findings[0].policyId == "chainguard-only@1"
  doAssert "Prefer Chainguard images" in policyOutcome.findings[0].reason
  let dict = policyOutcome.asChalkDict()
  doAssert not dict.hasKey("_POLICY_ID")
  doAssert dict.hasKey("_POLICY_RESULTS")

  # violates both, blocked by the enforced one
  (blocked, collected) = evaluateJson(multi, @[subject("busybox")])
  doAssert blocked and collected == 1
  doAssert policyOutcome.result == "blocked"
  doAssert results() == @[("golden-images@3", "blocked"), ("chainguard-only@1", "violation")]
  doAssert policyOutcome.findings.len == 2
  doAssert policyOutcome.findings[0].policyId == "golden-images@3"
  doAssert policyOutcome.findings[1].policyId == "chainguard-only@1"

  # all pass: nothing is reported
  (blocked, collected) = evaluateJson(multi, @[subject("cgr.dev/chainguard/static")])
  doAssert not blocked and policyOutcome == nil

proc testOnErrorPerPolicy() =
  let doc = """{"policies": [
    {"id": "lenient", "mode": "enforce", "on_error": "allow", "golden_images": {"enabled": true}},
    {"id": "strict",  "mode": "audit",   "on_error": "block", "golden_images": {"enabled": true}}
  ]}"""
  let errors = @[collectionError("image is not chalked", "img")]
  # neither an allowing enforced policy nor an audited one blocks on errors
  let (blocked, _) = evaluateJson(doc, @[], errors)
  doAssert not blocked
  doAssert results() == @[("lenient", "error"), ("strict", "error")]
  let (blockedStrict, _) = evaluateJson(doc.replace("\"audit\"", "\"enforce\""), @[], errors)
  doAssert blockedStrict
  doAssert results() == @[("lenient", "error"), ("strict", "blocked")]

proc testInvalidEntryIsIsolated() =
  let doc = """{"policies": [
    {"id": "broken", "mode": "enforce", "on_error": "block", "golden_images": {"enabled": 1}},
    {"id": "golden", "mode": "enforce", "golden_images": {"enabled": true,
     "allowed": [["glob", "alpine:*"]]}},
    {"id": "lenient", "mode": "enforce", "golden_images": {"enabled": 1}},
    {"id": "off", "mode": "off", "on_error": "block", "golden_images": {"enabled": 1}}
  ]}"""
  var (blocked, _) = evaluateJson(doc, @[subject("alpine:3.20")])
  # the broken entry blocks as it declares, without running rules
  doAssert blocked
  doAssert results() == @[("broken", "blocked"), ("golden", "pass"), ("lenient", "error")]
  doAssert policyOutcome.findings.len == 2
  doAssert policyOutcome.findings[0].rule == "config"
  doAssert policyOutcome.findings[0].policyId == "broken"
  doAssert "policy.policies[0].golden_images.enabled" in policyOutcome.findings[0].reason
  # the valid entry still enforces
  (blocked, _) = evaluateJson(doc, @[subject("busybox")])
  doAssert blocked
  doAssert results() == @[("broken", "blocked"), ("golden", "blocked"), ("lenient", "error")]

proc testRegisteredSection() =
  registerPolicyJsonSection("example_rule", proc(node: JsonNode, path: string) =
    node.validateFields([PolicyJsonField(name: "enabled", kind: JBool),
                         PolicyJsonField(name: "allowed", kind: JArray)], path))
  rejects("""{"example_rule": []}""", "policy.example_rule must be an object, got array")
  rejects("""{"example_rule": {"enabeld": true}}""", "unknown field policy.example_rule.enabeld")
  let configs = parsePolicyJson("""{"policies": [{"id": "a", "example_rule": {"enabled": 1}}]}""")
  doAssert "policy.policies[0].example_rule.enabled must be a boolean" in configs[0].configError
  setPolicyJson("""{"mode": "audit", "example_rule": {"enabled": true, "allowed": ["a", "b"]}}""")
  selectPolicy(policy())
  doAssert policyBoolSetting(["example_rule", "enabled"], false)
  doAssert policyStringsSetting(["example_rule", "allowed"]) == @["a", "b"]
  doAssert policyIntSetting(["example_rule", "max"], 3) == 3
  doAssertRaises(ValueError):
    registerPolicyJsonSection("example_rule", nil)
  doAssertRaises(ValueError):
    registerPolicyJsonSection("mode", nil)
  setPolicyJson("")

testValidation()
testRegisteredSection()
testFixture()
testDefaults()
testEnforcedFromJson()
testInvalidConfigHonorsDeclaredMode()
testMultiFixture()
testSingleObjectIsNotAList()
testEmptyListIsNoPolicy()
testIdsMustBeUnique()
testAuditAndEnforceDecideIndependently()
testOnErrorPerPolicy()
testInvalidEntryIsIsolated()
