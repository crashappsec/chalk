import std/[json, os, strutils, tables]
from std/unicode import validateUtf8
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/api
import ../../src/policy/dockerignore
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
  policyToolRunner = proc(request: ToolRequest, dir: string): ToolRun =
    assertEq(request.kind, "sast")
    calls.add(dir)
    if dir != "/src":
      raise newException(ValueError, "semgrep produced no SAST")
    ToolRun(outputs: @[ToolOutput(tool: "semgrep", root: dir, value: parseFile(sarifFile))])

  input = PolicyInput(command: "build", contextDirs: @["/src", "/other"], host: ChalkDict())
  (sources, errors) = input.collectSources(runTools = false, toolsRan = true)
  assertEq(len(sources), 0)
  doAssert "produced no results" in errors[0].reason
  (sources, errors) = input.collectSources(runTools = false, toolsRan = false)
  doAssert "were not collected" in errors[0].reason
  assertEq(len(calls), 0)

  # run_sast_tools produced nothing: run_tools scans the contexts instead
  (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
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

  # a tool that failed leaves the context partly unchecked, whatever the
  # others found
  clearPolicyToolCache()
  policyToolRunner = proc(request: ToolRequest, dir: string): ToolRun =
    ToolRun(outputs: @[ToolOutput(tool: "semgrep", root: dir, value: %*{"results": [], "errors": []})],
            failures: @["other: timed out"])
  input = PolicyInput(command: "build", contextDirs: @["/src"], host: ChalkDict())
  (sources, errors) = input.collectSources(runTools = true, toolsRan = false)
  assertEq(len(sources), 1)
  assertEq(len(errors), 1)
  doAssert "other: timed out" in errors[0].reason, errors[0].reason

  input = PolicyInput(command: "build", host: ChalkDict())
  (sources, errors) = input.collectSources(runTools = true, toolsRan = false)
  doAssert "no local build context" in errors[0].reason
  clearPolicyToolCache()

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

proc testSemgrepScanErrors() =
  let error = %*{"code": 3, "level": "warn", "type": "Syntax error", "path": "/src/app.py"}
  var source = SastSource(tool: "semgrep", roots: @["/src"], dir: "/src",
                          doc: %*{"results": [], "errors": [error]})
  let failures = defaults().check(@[source])
  assertEq(failures.len, 1)
  assertEq(failures[0].kind, "error")
  assertEq(failures[0].location, "app.py")
  for onError in ["allow", "block"]:
    let evaluated = evaluatePolicy(PolicyConfig(mode: "enforce", onError: onError),
                                    @[], PolicyInput(), failures)
    assertEq(evaluated.result, (if onError == "block": "blocked" else: "error"))
  # A partial scan must preserve valid findings alongside its error.
  source.doc["results"] = %*[{"check_id": "valid", "path": "/src/valid.py",
                             "extra": {"severity": "ERROR", "message": "valid finding"}}]
  let partial = defaults().check(@[source])
  assertEq(partial.len, 2)
  assertEq(partial[0].kind, "error")
  assertEq(partial[1].kind, "violation")
  assertEq(partial[1].subject, "valid")
  # Thresholds and suppressions affect matches, never scan failures.
  var config = defaults()
  config.maxFindings = 5
  config.ignorePaths = @["*"]
  assertEq(config.check(@[source]).len, 1)
  source.doc["results"] = newJArray()
  source.doc["errors"] = %*[{"level": "info", "type": "notice"}]
  assertEq(defaults().check(@[source]).len, 0)
  # semgrep's partial parses: the rest of the file was scanned
  source.doc["errors"] = %*[{"code": 3, "level": "warn", "path": "/src/app.py",
                             "type": ["PartialParsing", [{"path": "/src/app.py"}]]}]
  assertEq(defaults().check(@[source]).len, 0)
  source.doc["errors"] = %*[{"code": 2, "level": "warn", "type": "Timeout",
                             "rule_id": "r", "path": "/src/app.py"}]
  let timeout = defaults().check(@[source])
  assertEq(timeout.len, 1)
  doAssert "(Timeout)" in timeout[0].reason, timeout[0].reason
  source.doc["errors"] = %*[{"level": "warn", "path": "/sibling/app.py"}]
  assertEq(defaults().check(@[source]).len, 0)
  source.doc["errors"] = %*[{"level": "error", "type": "global scan error"}]
  assertEq(defaults().check(@[source])[0].kind, "error")
  source.doc["errors"] = %*{"malformed": true}
  assertEq(defaults().check(@[source])[0].kind, "error")

proc testSarifScanErrors() =
  var doc = parseFile(sarifFile)
  let notifications = doc["runs"][0]["invocations"][0]["toolExecutionNotifications"]
  var source = SastSource(tool: "semgrep", roots: @["/src"], dir: "/src", doc: doc)
  # notes do not make the scan incomplete
  notifications.add(%*{"descriptor": {"id": "Info"}, "level": "note",
                       "message": {"text": "x"}})
  assertEq(defaults().check(@[source]).ids(), @[shellTrue])
  doAssert not source.hasAmbiguousParse()
  for (id, level) in [("Timeout", "warning"), ("Fatal error", "error"),
                      ("Syntax error", "error"), ("Rule parse error", "")]:
    notifications.elems.setLen(1)
    var notification = %*{"descriptor": {"id": id}, "message": {"text": "x"}}
    if level != "":
      notification["level"] = %level
    notifications.add(notification)
    let findings = defaults().check(@[source])
    assertEq(findings.len, 2)
    assertEq(findings[0].kind, "error")
    doAssert id in findings[0].reason, findings[0].reason
    # matches are still reported
    assertEq(findings[1].subject, shellTrue)
  # located outside the build context of a monorepo
  notifications.elems.setLen(1)
  notifications.add(%*{"descriptor": {"id": "Timeout"}, "level": "warning",
                       "locations": [{"physicalLocation": {"artifactLocation": {"uri": "/web/a.py"}}}]})
  assertEq(defaults().check(@[source]).ids(), @[shellTrue])
  notifications[1]["locations"][0]["physicalLocation"]["artifactLocation"]["uri"] = %"/src/a.py"
  assertEq(defaults().check(@[source])[0].location, "a.py")

  # semgrep's notifications have no locations, the message has the path
  notifications.elems.setLen(1)
  notifications.add(%*{"descriptor": {"id": "Other syntax error"}, "level": "warning",
                       "message": {"text": "Other syntax error at line /web/chart.yaml:3:\n (approximate error location)"}})
  assertEq(defaults().check(@[source]).ids(), @[shellTrue])
  notifications[1]["message"]["text"] = %"Other syntax error at line src/chart.yaml:3:\n x"
  assertEq(defaults().check(@[source])[0].location, "src/chart.yaml")
  # or none that can be read: the error applies to the scan
  notifications[1]["message"]["text"] = %"Other syntax error in chart.yaml"
  let unlocated = defaults().check(@[source])
  assertEq(unlocated[0].kind, "error")
  assertEq(unlocated[0].location, "")

  # SARIF names partial parses `Syntax error` like files semgrep could not
  # parse at all, so both count, saying why
  notifications.elems.setLen(1)
  notifications.add(%*{"descriptor": {"id": "Syntax error"}, "level": "warning",
                       "message": {"text": "Syntax error at line /src/app.py:4:\n `x` was unexpected"}})
  let ambiguous = defaults().check(@[source])
  assertEq(ambiguous.len, 2)
  assertEq(ambiguous[0].kind, "error")
  assertEq(ambiguous[0].location, "app.py")
  doAssert "partial parses" in ambiguous[0].reason, ambiguous[0].reason
  doAssert source.hasAmbiguousParse()
  # unless docker does not send the file, or it is outside the context
  source.ignore = parseDockerignore("app.py\n")
  assertEq(defaults().check(@[source]).ids(), @[shellTrue])
  doAssert not source.hasAmbiguousParse()
  source.ignore = DockerIgnore()
  notifications[1]["message"]["text"] = %"Syntax error at line /web/app.py:4:"
  doAssert not source.hasAmbiguousParse()
  # semgrep JSON tells them apart, see testSemgrepScanErrors
  doAssert not SastSource(tool: "semgrep", dir: "/src",
                          doc: %*{"results": [], "errors": []}).hasAmbiguousParse()

  doc["runs"][0]["invocations"][0]["toolExecutionNotifications"] = %"bad"
  assertEq(defaults().check(@[source])[0].kind, "error")

proc testDockerignore() =
  # results and scan errors in files docker does not send do not count
  var source = SastSource(tool: "semgrep", roots: @["/src"], dir: "/src",
                          doc: parseFile(jsonFile),
                          ignore: parseDockerignore("src/app.py\n"))
  assertEq(len(source.parseSastSource()), 0)
  source.ignore = parseDockerignore("src/*\n!src/app.py\n")
  assertEq(defaults().check(@[source])[0].location, "src/app.py:8")
  source.ignore = parseDockerignore("src/app.py\n")
  source.doc = %*{"results": [], "errors": [
    {"level": "warn", "type": "Syntax error", "path": "/src/src/app.py"}]}
  assertEq(defaults().check(@[source]).len, 0)
  source.ignore = DockerIgnore()
  assertEq(defaults().check(@[source]).len, 1)

  # collected per context: `<Dockerfile>.dockerignore` for the main one
  let dir = getTempDir() / "chalk-sast-dockerignore"
  removeDir(dir)
  createDir(dir / "main")
  createDir(dir / "named")
  writeFile(dir / "main" / ".dockerignore", "ignored-by-main.py\n")
  writeFile(dir / "Dockerfile", "FROM alpine\n")
  writeFile(dir / "Dockerfile.dockerignore", "ignored-by-dockerfile.py\n")
  writeFile(dir / "named" / ".dockerignore", "ignored-by-named.py\n")
  clearPolicyToolCache()
  policyToolRunner = proc(request: ToolRequest, dir: string): ToolRun =
    ToolRun(outputs: @[ToolOutput(tool: "semgrep", root: dir, value: %*{"results": [], "errors": []})])
  let input = PolicyInput(command: "build", contextDirs: @[dir / "main", dir / "named"],
                          mainContextDir: dir / "main", dockerfilePath: dir / "Dockerfile",
                          host: ChalkDict())
  let (sources, errors) = input.collectSources(runTools = true, toolsRan = false)
  assertEq(len(errors), 0)
  assertEq(len(sources), 2)
  doAssert sources[0].ignore.isIgnored("ignored-by-dockerfile.py")
  doAssert not sources[0].ignore.isIgnored("ignored-by-main.py")
  doAssert sources[1].ignore.isIgnored("ignored-by-named.py")
  clearPolicyToolCache()
  removeDir(dir)

proc testAmbiguousHostSarif() =
  # with run_tools, contexts whose run_sast_tools SARIF has ambiguous parse
  # errors are scanned by the rule, whose semgrep JSON tells them apart
  var doc = parseFile(sarifFile)
  doc["runs"][0]["invocations"][0]["toolExecutionNotifications"] = %*[
    {"descriptor": {"id": "Syntax error"}, "level": "warning",
     "message": {"text": "Syntax error at line /repo/app/x.js:1:"}}]
  var host = ChalkDict()
  host["SAST"] = nimJsonToBox(%*{"semgrep": doc})
  host["EXTERNAL_TOOL_DURATION"] = nimJsonToBox(%*{"semgrep": {"/repo": 1200}})
  clearPolicyToolCache()
  var calls: seq[string]
  policyToolRunner = proc(request: ToolRequest, dir: string): ToolRun =
    calls.add(dir)
    ToolRun(outputs: @[ToolOutput(tool: "semgrep", root: dir, value: %*{"results": [], "errors": []})])
  var input = PolicyInput(command: "build", contextDirs: @["/repo/app"], host: host)
  var (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
  assertEq(calls, @["/repo/app"])
  assertEq(len(errors), 0)
  assertEq(len(sources), 1)
  assertEq(len(defaults().check(sources)), 0)
  # in another context of the repository: run_sast_tools' output is used
  input.contextDirs = @["/repo/web"]
  (sources, errors) = input.collectSources(runTools = true, toolsRan = true)
  assertEq(calls, @["/repo/app"])
  assertEq(sources[0].roots, @["/repo"])
  # without run_tools it is reported as unchecked
  input.contextDirs = @["/repo/app"]
  (sources, errors) = input.collectSources(runTools = false, toolsRan = true)
  assertEq(calls, @["/repo/app"])
  let findings = defaults().check(sources)
  assertEq(findings[0].kind, "error")
  doAssert "partial parses" in findings[0].reason, findings[0].reason
  clearPolicyToolCache()

proc testTruncateRunes() =
  # a long message is cut by characters, never inside a UTF-8 sequence
  let message = repeat("é", 400)
  let json = %*{"results": [{"check_id": "r", "path": "a.py", "start": {"line": 1},
                             "extra": {"severity": "ERROR", "message": message}}]}
  let reason = defaults().check(@[SastSource(tool: "semgrep", doc: json)])[0].reason
  doAssert validateUtf8(reason) == -1, reason
  doAssert reason.endsWith("...")

proc testSecretMessages() =
  let secret = "hunter2supersecret"
  let json = %*{"results": [
    {"check_id": "custom.hardcoded", "path": "a.py", "start": {"line": 1},
     "extra": {"severity": "ERROR", "message": "found " & secret,
               "metadata": {"cwe": ["CWE-798: Use of Hard-coded Credentials"]}}},
    {"check_id": "custom.leak", "path": "b.py", "start": {"line": 1},
     "extra": {"severity": "ERROR", "message": "found " & secret,
               "metadata": {"technology": ["secrets"]}}},
    {"check_id": "generic.secrets.security.detected-aws-access-key", "path": "c.py",
     "start": {"line": 1}, "extra": {"severity": "ERROR", "message": "found " & secret}},
    {"check_id": "custom.shell", "path": "d.py", "start": {"line": 1},
     "extra": {"severity": "ERROR", "message": "shell=True with " & secret}},
  ]}
  let findings = defaults().check(@[SastSource(tool: "semgrep", doc: json)])
  assertEq(findings.len, 4)
  for f in findings[0 ..< 3]:
    doAssert secret notin f.reason, f.reason
    doAssert "message omitted" in f.reason, f.reason
    doAssert f.location != ""
  doAssert secret in findings[3].reason
  let sarif = %*{"runs": [{
    "tool": {"driver": {"name": "semgrep", "rules": [
      {"id": "custom.hardcoded", "defaultConfiguration": {"level": "error"},
       "properties": {"tags": ["CWE-798: Use of Hard-coded Credentials", "security"]}},
    ]}},
    "results": [{"ruleId": "custom.hardcoded", "message": {"text": "found " & secret},
                 "locations": [{"physicalLocation": {"artifactLocation": {"uri": "a.py"},
                                                     "region": {"startLine": 3}}}]}],
  }]}
  let sarifFindings = defaults().check(@[SastSource(tool: "semgrep", doc: sarif)])
  assertEq(sarifFindings.len, 1)
  doAssert secret notin sarifFindings[0].reason, sarifFindings[0].reason
  assertEq(sarifFindings[0].location, "a.py:3")

proc testRequiresContext() =
  # contextDirs is only collected for rules requiring it; without it every
  # build would pass unscanned
  loadSastRule()
  var found = false
  for rule in policyRules():
    if rule.name == "sast":
      found = true
      doAssert rule.requiresContext
      doAssert rule.checkInput != nil
  doAssert found

testSeverityMapping()
testParseSarif()
testParseJson()
testSecuritySeverity()
testThresholds()
testOrderingAndCap()
testBadOutput()
testCollectSources()
testConfig()
testSemgrepScanErrors()
testSarifScanErrors()
testDockerignore()
testAmbiguousHostSarif()
testTruncateRunes()
testSecretMessages()
testRequiresContext()
