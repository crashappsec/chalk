import std/[os, strutils]
import ../../src/types
import ../../src/policy/engine
import ../../src/policy/rules/golden_images
import ../../src/docker/ids

const fixture = currentSourcePath().parentDir() / "fixtures" / "policy_config.json"

proc rejects(text, reason: string) =
  try:
    discard parsePolicyJson(text)
    doAssert false, "accepted: " & text
  except ValueError:
    doAssert reason in getCurrentExceptionMsg(), getCurrentExceptionMsg()

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
  discard parsePolicyJson("{}")

proc testFixture() =
  setPolicyJson(readFile(fixture))
  let settings = policyControls()
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
  doAssert policyControls().onError == "allow"
  doAssert loadGoldenImagesConfig().isNone()
  setPolicyJson("""{"mode": "audit", "golden_images": {"enabled": true}}""")
  let golden = loadGoldenImagesConfig().get()
  doAssert golden.checkCopyFrom and golden.allowed.len == 0

proc build(): ChalkDict =
  result = ChalkDict()
  result["command"] = pack("build")

proc testEnforcedFromJson() =
  setPolicyJson(readFile(fixture))
  policyOutcome = nil
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
    evaluatePolicies(policyControls(), @[rule], PolicyInput(subjects: @[subject]), build())
  except PolicyViolation:
    blocked = true
  doAssert blocked
  doAssert policyOutcome.id == "golden-images@3"
  doAssert policyOutcome.asChalkDict().hasKey("_POLICY_ID")

proc testInvalidJsonReportsAndNeverBlocks() =
  # even if the broken document asks for enforce
  setPolicyJson("""{"mode": "enforce", "on_error": "block", "golden_images": {"enabled": 1}}""")
  doAssert policyEnabled()
  policyOutcome = nil
  var collected = false
  evaluatePolicies(build(), proc(): PolicyInput =
    collected = true
    PolicyInput())
  doAssert not collected
  doAssert policyOutcome.result == "error"
  doAssert policyOutcome.findings.len == 1
  doAssert policyOutcome.findings[0].rule == "config"
  doAssert "policy.golden_images.enabled" in policyOutcome.findings[0].reason
  doAssert not policyOutcome.asChalkDict().hasKey("_POLICY_ID")

testValidation()
testFixture()
testDefaults()
testEnforcedFromJson()
testInvalidJsonReportsAndNeverBlocks()
