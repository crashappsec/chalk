import std/[strutils]
import ../../src/types
import ../../src/policy/engine
import ../../src/policy/rules/golden_images
import ../../src/docker/ids

proc passing(subjects: seq[PolicySubject]): seq[PolicyFinding] =
  discard

proc rule(name: string, requiresAllSubjects: bool,
          check: proc(subjects: seq[PolicySubject]): seq[PolicyFinding] = passing): PolicyRule =
  PolicyRule(name: name, requiresAllSubjects: requiresAllSubjects,
             load: proc(): bool = true, check: check)

proc evaluate(mode, onError: string, rules: seq[PolicyRule], input: PolicyInput): bool =
  ## true when blocked
  policyOutcome = nil
  let build = ChalkDict()
  build["command"] = pack("build")
  try:
    evaluatePolicies(PolicyConfig(mode: mode, onError: onError), rules, input, build)
  except PolicyViolation:
    return true

proc testOnError() =
  let input = PolicyInput(errors: @[collectionError("malformed image metadata")])
  for mode in ["audit", "enforce"]:
    for onError in ["allow", "block"]:
      let blocked = evaluate(mode, onError, @[rule("golden_images", true)], input)
      doAssert blocked == (mode == "enforce" and onError == "block")
      doAssert policyOutcome != nil and policyOutcome.findings.len == 1
      doAssert policyOutcome.findings[0].rule == "golden_images"
      doAssert policyOutcome.result == (if blocked: "blocked" else: "error")

proc testCollectionErrorsOnlyForRulesNeedingAllSubjects() =
  # e.g. pushing an unchalked image with only custom_check configured
  let input = PolicyInput(errors: @[collectionError("image is not chalked", "img")])
  doAssert not evaluate("enforce", "block", @[rule("custom_check", false)], input)
  doAssert policyOutcome == nil
  doAssert evaluate("enforce", "block",
                    @[rule("custom_check", false), rule("a", true), rule("b", true)], input)
  doAssert policyOutcome.findings.len == 2
  doAssert policyOutcome.findings[0].rule == "a" and policyOutcome.findings[1].rule == "b"
  doAssert policyOutcome.findings[0].image == "img"

proc testRuleFailureIsAnError() =
  let failing = rule("broken", false, proc(subjects: seq[PolicySubject]): seq[PolicyFinding] =
    raise newException(ValueError, "boom"))
  doAssert not evaluate("enforce", "allow", @[failing], PolicyInput())
  doAssert policyOutcome.findings[0].rule == "broken"
  doAssert policyOutcome.findings[0].kind == "error"
  doAssert evaluate("enforce", "block", @[failing], PolicyInput())

proc testGoldenImagesRule() =
  let subject = PolicySubject(image: parseImage("busybox"), raw: "busybox", source: "copy_from")
  var settings = GoldenImagesConfig(checkCopyFrom: false, allowed: @[("glob", "alpine:*")])
  doAssert settings.check(@[subject]).len == 0
  settings.checkCopyFrom = true
  settings.message = "use alpine"
  let findings = settings.check(@[subject])
  doAssert findings.len == 1 and findings[0].kind == "violation"
  doAssert findings[0].rule == "golden_images" and findings[0].reason.endsWith("use alpine")
  let golden = rule("golden_images", true, proc(subjects: seq[PolicySubject]): seq[PolicyFinding] =
    settings.check(subjects))
  doAssert evaluate("enforce", "allow", @[golden], PolicyInput(subjects: @[subject]))
  doAssert not evaluate("audit", "allow", @[golden], PolicyInput(subjects: @[subject]))
  doAssert policyOutcome.result == "violation"

proc testModeOff() =
  let input = PolicyInput(errors: @[collectionError("x")])
  doAssert not evaluate("off", "block", @[rule("golden_images", true)], input)
  doAssert policyOutcome == nil

testOnError()
testCollectionErrorsOnlyForRulesNeedingAllSubjects()
testRuleFailureIsAnError()
testGoldenImagesRule()
testModeOff()
