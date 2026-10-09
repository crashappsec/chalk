import std/[json, os, strutils, tables]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/engine
import ../../src/policy/tools
import ../../src/policy/rules/sast

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const
  fixtures   = currentSourcePath().parentDir() / "fixtures"
  # real `semgrep scan --config=auto` output of a small python project mounted
  # at /src, trimmed to the rules it matched
  sarifFile  = fixtures / "semgrep_results.sarif.json"
  jsonFile   = fixtures / "semgrep_results.json"
  shellTrue  = "python.lang.security.audit.subprocess-shell-true.subprocess-shell-true"
  pickle     = "python.lang.security.deserialization.pickle.avoid-pickle"
  evalRule   = "python.lang.security.audit.eval-detected.eval-detected"

proc source(file: string, tool = "semgrep"): SastSource =
  SastSource(tool: tool, doc: parseFile(file), roots: @["/src"])

proc defaults(): SastConfig =
  SastConfig(minSeverity: "high", minConfidence: "low", includeAudit: true)

proc ids(findings: seq[PolicyFinding]): seq[string] =
  for f in findings:
    result.add(f.subject)

proc sastDict(file: string, scanned = ""): ChalkDict =
  result = ChalkDict()
  let tools = newJObject()
  tools["semgrep"] = parseFile(file)
  result["SAST"] = nimJsonToBox(tools)
  if scanned != "":
    result["EXTERNAL_TOOL_DURATION"] = nimJsonToBox(%*{"semgrep": {scanned: 1200}})

proc testSeverityMapping() =
  assertEq(semgrepSeverity("CRITICAL"), "critical")
  assertEq(semgrepSeverity("ERROR"), "high")
  assertEq(semgrepSeverity("HIGH"), "high")
  assertEq(semgrepSeverity("WARNING"), "medium")
  assertEq(semgrepSeverity("medium"), "medium")
  assertEq(semgrepSeverity("INFO"), "low")
  assertEq(semgrepSeverity("LOW"), "low")
  assertEq(semgrepSeverity("INVENTORY"), "info")
  assertEq(sarifLevelSeverity("error"), "high")
  assertEq(sarifLevelSeverity("warning"), "medium")
  assertEq(sarifLevelSeverity("note"), "low")
  assertEq(sarifLevelSeverity("none"), "info")
  assertEq(sarifLevelSeverity(""), "medium")
  assertEq(securitySeveritySeverity(9.8), "critical")
  assertEq(securitySeveritySeverity(7.0), "high")
  assertEq(securitySeveritySeverity(5.5), "medium")
  assertEq(securitySeveritySeverity(2.0), "low")
  assertEq(securitySeveritySeverity(0.0), "info")

proc testParseSarif() =
  let results = parseSastSource(source(sarifFile))
  # the `# nosemgrep` match is reported as suppressed and skipped
  assertEq(len(results), 3)
  let r = results[0]
  assertEq(r.ruleId, shellTrue)
  assertEq(r.path, "src/app.py")
  assertEq(r.line, 8)
  assertEq(r.severity, "high")
  assertEq(r.confidence, "medium")
  assertEq(r.cwes, @["CWE-78"])
  doAssert "security" in r.categories
  # SARIF drops the subcategory
  assertEq(len(r.subcategories), 0)
  assertEq(results[1].ruleId, pickle)
  assertEq(results[1].severity, "medium")
  assertEq(results[1].confidence, "low")
  assertEq(results[2].ruleId, evalRule)

proc testParseJson() =
  let results = parseSastSource(source(jsonFile))
  assertEq(len(results), 3)
  let r = results[0]
  assertEq(r.ruleId, shellTrue)
  assertEq(r.path, "src/app.py")
  assertEq(r.line, 8)
  assertEq(r.severity, "high")
  assertEq(r.confidence, "medium")
  assertEq(r.cwes, @["CWE-78"])
  assertEq(r.categories, @["security"])
  assertEq(r.subcategories, @["secure default"])
  doAssert not r.isAudit()
  doAssert results[1].isAudit()

proc testSecuritySeverity() =
  let doc = %*{"runs": [{
    "tool": {"driver": {"name": "other", "rules": [
      {"id": "a", "defaultConfiguration": {"level": "error"},
       "properties": {"security-severity": "9.1"}},
      {"id": "b", "properties": {"security-severity": 5}},
      {"id": "c", "defaultConfiguration": {"level": "note"},
       "properties": {"security-severity": "n/a"}},
    ]}},
    "results": [
      {"ruleId": "a", "message": {"text": "x"}},
      {"rule": {"id": "b"}, "message": {"text": "y"}},
      {"ruleIndex": 2},
      {"ruleId": "d", "level": "error"},
    ],
  }]}
  let results = parseSastSource(SastSource(tool: "other", doc: doc))
  assertEq(results[0].severity, "critical")
  assertEq(results[1].ruleId, "b")
  assertEq(results[1].severity, "medium")
  assertEq(results[2].ruleId, "c")
  assertEq(results[2].severity, "low")
  assertEq(results[3].severity, "high")
  let critical = SastConfig(minSeverity: "critical", minConfidence: "low", includeAudit: true)
  assertEq(critical.check(@[SastSource(tool: "other", doc: doc)]).ids(), @["a"])

proc testThresholds() =
  let sources = @[source(sarifFile)]
  var settings = defaults()
  let findings = settings.check(sources)
  assertEq(findings.ids(), @[shellTrue])
  let f = findings[0]
  assertEq(f.rule, "sast")
  assertEq(f.kind, "violation")
  assertEq(f.location, "src/app.py:8")
  assertEq(f.severity, "high")
  assertEq(f.image, "")
  doAssert f.reason.startsWith("high semgrep finding: Found 'subprocess'"), f.reason

  settings.minSeverity = "medium"
  assertEq(settings.check(sources).ids(), @[shellTrue, pickle, evalRule])
  settings.minConfidence = "medium"
  assertEq(settings.check(sources).ids(), @[shellTrue])
  settings.minConfidence = "high"
  assertEq(len(settings.check(sources)), 0)
  settings.minConfidence = "low"

  settings.categories = @["correctness"]
  assertEq(len(settings.check(sources)), 0)
  settings.categories = @["Security"]
  assertEq(len(settings.check(sources)), 3)
  settings.categories = @[]

  settings.cwes = @["cwe-78"]
  assertEq(settings.check(sources).ids(), @[shellTrue])
  settings.cwes = @["CWE-9*"]
  assertEq(settings.check(sources).ids(), @[evalRule])
  settings.cwes = @[]

  settings.ignoreRules = @["python.lang.security.audit.*"]
  assertEq(settings.check(sources).ids(), @[pickle])
  settings.ignoreRules = @[]
  settings.ignorePaths = @["src/*"]
  assertEq(len(settings.check(sources)), 0)
  settings.ignorePaths = @["tests/*"]
  assertEq(len(settings.check(sources)), 3)
  settings.ignorePaths = @[]

  # SARIF: approximated from the rule id
  settings.includeAudit = false
  assertEq(settings.check(sources).ids(), @[pickle])
  # JSON: exact `metadata.subcategory`
  assertEq(settings.check(@[source(jsonFile)]).ids(), @[shellTrue])
  settings.includeAudit = true

  settings.maxFindings = 3
  assertEq(len(settings.check(sources)), 0)
  settings.maxFindings = 2
  assertEq(len(settings.check(sources)), 3)

  settings = defaults()
  settings.message = "See https://example.com/sast"
  doAssert settings.check(sources)[0].reason.endsWith(". See https://example.com/sast")

proc testOrderingAndCap() =
  var results = newJArray()
  for i in 0 ..< 150:
    results.add(%*{"check_id": "r" & $i, "path": "a.py", "start": {"line": i + 1},
                   "extra": {"severity": (if i == 149: "CRITICAL" else: "ERROR"),
                             "message": repeat("m", 1000)}})
  let findings = defaults().check(@[SastSource(tool: "semgrep", doc: %*{"results": results})])
  assertEq(len(findings), 101)
  assertEq(findings[0].subject, "r149")
  assertEq(findings[0].severity, "critical")
  doAssert len(findings[1].reason) < 400
  doAssert findings[^1].reason.startsWith("50 more SAST findings")

proc testBadOutput() =
  let unsuccessful = %*{"runs": [{"invocations": [{"executionSuccessful": false}], "results": []}]}
  for doc in [unsuccessful, %*{"foo": 1}, %*[1]]:
    let findings = defaults().check(@[SastSource(tool: "semgrep", doc: doc)])
    assertEq(len(findings), 1)
    assertEq(findings[0].kind, "error")
    assertEq(findings[0].subject, "semgrep")

proc testCollectSources() =
  # push: only what the mark recorded, nothing to evaluate otherwise
  var input = PolicyInput(command: "push", pushTargets: @["app:2"], pushMarks: @[ChalkDict()])
  var (sources, errors) = input.collectSources(runTools = true, toolsRan = false)
  assertEq(len(sources), 0)
  assertEq(len(errors), 0)
  input.pushMarks.add(sastDict(sarifFile, scanned = "/src"))
  (sources, errors) = input.collectSources(runTools = true, toolsRan = false)
  assertEq(len(sources), 1)
  assertEq(sources[0].image, "app:2")
  assertEq(sources[0].roots, @["/src"])
  let pushed = defaults().check(sources)
  assertEq(pushed[0].location, "src/app.py:8")
  doAssert pushed[0].reason.endsWith("(in app:2)"), pushed[0].reason

  # build: results run_sast_tools collected for the repository containing
  # the context, limited to the context directory
  input = PolicyInput(command: "build", contextDirs: @["/src"], host: sastDict(jsonFile, scanned = "/src"))
  (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
  assertEq(len(sources), 1)
  assertEq(len(errors), 0)
  assertEq(sources[0].tool, "semgrep")
  assertEq(sources[0].dir, "/src")
  assertEq(defaults().check(sources)[0].location, "src/app.py:8")
  input.contextDirs = @["/src/src"]
  (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
  assertEq(defaults().check(sources)[0].location, "app.py:8")
  input.contextDirs = @["/src/web"]
  (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
  assertEq(len(sources), 1)
  assertEq(len(defaults().check(sources)), 0)

  clearPolicyToolCache()
  var calls: seq[string]
  policyToolRunner = proc(request: ToolRequest, dir: string): seq[ToolOutput] =
    assertEq(request.kind, "sast")
    calls.add(dir)
    if dir != "/src":
      raise newException(ValueError, "semgrep produced no SAST")
    @[ToolOutput(tool: "semgrep", root: dir, value: parseFile(sarifFile))]

  input = PolicyInput(command: "build", contextDirs: @["/src", "/other"], host: ChalkDict())
  (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
  assertEq(len(sources), 0)
  doAssert "produced no results" in errors[0].reason
  (sources, errors) = input.collectSources(runTools = false, toolsRan = false)
  doAssert "were not collected" in errors[0].reason
  assertEq(len(calls), 0)

  (sources, errors) = input.collectSources(runTools = true, toolsRan = false)
  assertEq(calls, @["/src", "/other"])
  assertEq(len(sources), 1)
  assertEq(sources[0].roots, @["/src"])
  assertEq(len(errors), 1)
  assertEq(errors[0].kind, "error")
  assertEq(errors[0].subject, "/other")
  # another policy enabling the rule reuses the scans
  discard input.collectSources(runTools = true, toolsRan = false)
  assertEq(len(calls), 2)

  # contexts run_sast_tools did not cover are scanned too
  input = PolicyInput(command: "build", contextDirs: @["/repo", "/src"],
                      host: sastDict(jsonFile, scanned = "/repo"))
  (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
  assertEq(len(errors), 0)
  assertEq(len(sources), 2)
  assertEq(len(calls), 2)

  input = PolicyInput(command: "build", host: ChalkDict())
  (sources, errors) = input.collectSources(runTools = true, toolsRan = false)
  doAssert "no local build context" in errors[0].reason
  clearPolicyToolCache()

proc rejects(text, reason: string) =
  try:
    discard parsePolicyJson(text)
    doAssert false, "accepted: " & text
  except ValueError:
    doAssert reason in getCurrentExceptionMsg(), getCurrentExceptionMsg()

proc testConfig() =
  rejects("""{"sast": {"enabeld": true}}""", "unknown field policy.sast.enabeld")
  rejects("""{"sast": {"min_severity": "error"}}""", "policy.sast.min_severity must be one of")
  rejects("""{"sast": {"min_confidence": "very-high"}}""", "policy.sast.min_confidence must be one of")
  rejects("""{"sast": {"categories": [1]}}""", "policy.sast.categories entries must be strings")
  rejects("""{"sast": {"max_findings": -1}}""", "policy.sast.max_findings must not be negative")
  rejects("""{"sast": {"max_findings": "3"}}""", "policy.sast.max_findings must be a number")
  rejects("""{"sast": []}""", "policy.sast must be an object")

  setPolicyJson("""{"mode": "audit"}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadSastConfig().isNone()

  setPolicyJson("""{"mode": "audit", "sast": {"enabled": true}}""")
  selectPolicy(policyConfigs()[0])
  let d = loadSastConfig().get()
  assertEq(d.minSeverity, "high")
  assertEq(d.minConfidence, "low")
  doAssert d.includeAudit and d.runTools
  assertEq(d.maxFindings, 0)

  setPolicyJson($(%*{"policies": [
    {"id": "sast@1", "mode": "enforce", "sast": {
      "enabled": true, "min_severity": "medium", "min_confidence": "medium",
      "categories": ["security"], "cwes": ["CWE-78"], "ignore_rules": ["x.*"],
      "ignore_paths": ["tests/*"], "include_audit": false, "max_findings": 2,
      "run_tools": false, "message": "fix it"}},
    {"id": "other@1", "mode": "audit"},
  ]}))
  let policies = policyConfigs()
  assertEq(policies[0].configError, "")
  selectPolicy(policies[0])
  let s = loadSastConfig().get()
  assertEq(s.minSeverity, "medium")
  assertEq(s.minConfidence, "medium")
  assertEq(s.categories, @["security"])
  assertEq(s.cwes, @["CWE-78"])
  assertEq(s.ignoreRules, @["x.*"])
  assertEq(s.ignorePaths, @["tests/*"])
  doAssert not s.includeAudit and not s.runTools
  assertEq(s.maxFindings, 2)
  assertEq(s.message, "fix it")
  selectPolicy(policies[1])
  doAssert loadSastConfig().isNone()
  setPolicyJson("")

testSeverityMapping()
testParseSarif()
testParseJson()
testSecuritySeverity()
testThresholds()
testOrderingAndCap()
testBadOutput()
testCollectSources()
testConfig()
