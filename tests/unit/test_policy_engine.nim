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

proc testInputRule() =
  var seen: PolicyInput
  let host = ChalkDict()
  host["SAST"] = pack("results")
  let inputRule = PolicyRule(name: "sast", load: proc(): bool = true,
    checkInput: proc(input: PolicyInput): seq[PolicyFinding] =
      seen = input
      @[newSubjectFinding("sast", "violation", "src/app.py", "high severity finding",
                          location = "src/app.py:3", severity = "high")])
  let input = PolicyInput(command: "build", contextDirs: @["/ctx"],
                          pushTargets: @["ghcr.io/acme/app:1"], host: host)
  doAssert evaluate("enforce", "allow", @[inputRule], input)
  doAssert seen.contextDirs == @["/ctx"] and seen.pushTargets == @["ghcr.io/acme/app:1"]
  doAssert "SAST" in seen.host
  let f = policyOutcome.findings[0]
  doAssert f.subject == "src/app.py" and f.location == "src/app.py:3" and f.severity == "high"
  doAssert $f == "sast: src/app.py (src/app.py:3) - high severity finding"
  let report = unpack[seq[Box]](policyOutcome.asChalkDict()["_POLICY_FINDINGS"])
  doAssert unpack[TableRef[string, string]](report[0])["severity"] == "high"

proc testInputCollectionFailure() =
  var checks = 0
  let fileRule = PolicyRule(name: "certificates", load: proc(): bool = true,
    checkInput: proc(input: PolicyInput): seq[PolicyFinding] =
      inc(checks))
  let input = PolicyInput(collectionFailed: true,
    errors: @[collectionError("could not check out Git context")])
  doAssert evaluate("enforce", "block", @[fileRule], input)
  doAssert checks == 0
  doAssert policyOutcome.findings.len == 1
  doAssert policyOutcome.findings[0].rule == "certificates"
  doAssert not evaluate("enforce", "allow", @[fileRule], input)
  doAssert policyOutcome.result == "error"
  # An individual unresolved image still does not prevent file rules running.
  doAssert not evaluate("enforce", "block", @[fileRule],
    PolicyInput(errors: @[collectionError("unresolved image")]))
  doAssert checks == 1

proc testCollectorFailureForMultiplePolicies() =
  setPolicyJson("""{"policies":[
    {"id":"blocked","mode":"enforce","on_error":"block"},
    {"id":"audited","mode":"audit","on_error":"block"}
  ]}""")
  policyOutcome = nil
  var collections, checks = 0
  let collect = proc(): PolicyInput =
    inc(collections)
    raise newException(ValueError, "Git checkout failed")
  let fileRule = PolicyRule(name: "certificates", load: proc(): bool = true,
    checkInput: proc(input: PolicyInput): seq[PolicyFinding] =
      inc(checks))
  let build = ChalkDict()
  build["command"] = pack("build")
  doAssertRaises(PolicyViolation):
    evaluatePolicies(build, collect, @[fileRule])
  doAssert collections == 1 and checks == 0
  doAssert policyOutcome.policies.len == 2
  doAssert policyOutcome.policies[0].result == "blocked"
  doAssert policyOutcome.policies[1].result == "error"
  doAssert policyOutcome.findings.len == 2
  setPolicyJson("")

testOnError()
testInputRule()
testInputCollectionFailure()
testCollectionErrorsOnlyForRulesNeedingAllSubjects()
testRuleFailureIsAnError()
testGoldenImagesRule()
testModeOff()
testCollectorFailureForMultiplePolicies()
