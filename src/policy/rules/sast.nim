##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.sast`: block builds whose SAST scan (semgrep by default) reports
## findings at or above a severity threshold. Reads SARIF (chalk's default
## semgrep output) and semgrep's native JSON. See docs/design-build-policy.md.

import std/[
  algorithm,
  json,
  os,
  strutils,
  tables,
]
import "../.."/[
  types,
]
import ".."/[
  api,
  configuration,
  tools,
]
import "."/[
  golden_images,
]

const
  ruleName = "sast"
  severities* = ["info", "low", "medium", "high", "critical"]
  confidences* = ["low", "medium", "high"]
  # keeps reports and the job summary bounded on noisy codebases
  maxReportedFindings = 100
  maxMessageLen = 300

type
  SastResult* = object
    tool*:          string
    ruleId*:        string
    path*:          string # relative to the build context (push: the scanned directory) when known
    line*:          int
    severity*:      string # one of `severities`
    confidence*:    string # one of `confidences`, empty when unknown
    categories*:    seq[string] # lowercase
    cwes*:          seq[string] # e.g. `CWE-78`
    subcategories*: seq[string] # lowercase, e.g. `vuln`, `audit`
    message*:       string

  SastSource* = object
    ## one tool's output, e.g. `SAST.semgrep`
    tool*:  string
    doc*:   JsonNode
    roots*: seq[string] # directories the tool scanned
    image*: string      # pushed image whose mark recorded it, empty on build
    ## build context directory: results outside it are dropped and paths are
    ## relative to it; empty on push
    dir*:   string

  SastConfig* = object
    minSeverity*:   string
    minConfidence*: string
    categories*:    seq[string]
    cwes*:          seq[string]
    ignoreRules*:   seq[string]
    ignorePaths*:   seq[string]
    includeAudit*:  bool
    maxFindings*:   int
    runTools*:      bool
    message*:       string

proc rank(scale: openArray[string], value: string): int =
  scale.find(value)

proc semgrepSeverity*(value: string): string =
  ## Rule severities as semgrep reports them in JSON. ERROR/WARNING/INFO are
  ## the legacy names of HIGH/MEDIUM/LOW
  ## (https://semgrep.dev/docs/contributing/contributing-to-semgrep-rules-repository).
  case value.toUpperAscii()
  of "CRITICAL":        "critical"
  of "ERROR", "HIGH":   "high"
  of "WARNING", "MEDIUM": "medium"
  of "INFO", "LOW":     "low"
  # EXPERIMENT, INVENTORY and anything newer are not findings to act on
  else:                 "info"

proc sarifLevelSeverity*(level: string): string =
  ## semgrep maps CRITICAL and HIGH to `error`, so SARIF levels cannot tell
  ## them apart
  case level
  of "error":   "high"
  of "warning": "medium"
  of "note":    "low"
  of "none":    "info"
  # https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html#_Toc34317648
  # a missing level defaults to "warning"
  else:         "medium"

proc securitySeveritySeverity*(score: float): string =
  ## `security-severity` is a CVSS-like 0-10 score, bucketed as GitHub does
  ## (https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning#reportingdescriptor-object)
  if score >= 9.0:   "critical"
  elif score >= 7.0: "high"
  elif score >= 4.0: "medium"
  elif score >= 0.1: "low"
  else:              "info"

proc parseScore(node: JsonNode): float =
  ## raises ValueError when not a number or a numeric string
  case node.kind
  of JInt, JFloat: node.getFloat()
  of JString:      parseFloat(node.getStr())
  else: raise newException(ValueError, "not a number")

proc strings(node: JsonNode): seq[string] =
  ## semgrep metadata values are a string or a list of strings
  if node == nil:
    return
  case node.kind
  of JString:
    result.add(node.getStr())
  of JArray:
    for item in node:
      if item.kind == JString:
        result.add(item.getStr())
  else:
    discard

proc cweId(value: string): string =
  ## `CWE-78: Improper Neutralization ...` -> `CWE-78`
  value.split(':', maxsplit = 1)[0].strip().toUpperAscii()

proc relativeTo(path: string, roots: seq[string]): string =
  result = path
  for root in roots:
    let prefix = root.strip(leading = false, chars = {'/'}) & "/"
    if result.startsWith(prefix):
      return result[len(prefix) .. ^1]

proc resultPath(source: SastSource, path: string): Option[string] =
  ## On build, relative to the context directory, `none` outside it, as
  ## chalk scans the whole repository of a monorepo; on push, relative to
  ## the directory scanned when the image was built.
  var path = path
  if path.startsWith("file://"):
    path = path[len("file://") .. ^1]
  if source.dir == "":
    return some(path.relativeTo(source.roots))
  let root =
    if path.isAbsolute(): "/"
    elif len(source.roots) > 0: source.roots[0]
    else: ""
  path.contextPath(root, source.dir)

proc truncate(s: string): string =
  let flat = s.strip().replace('\n', ' ')
  if len(flat) <= maxMessageLen:
    return flat
  flat[0 ..< maxMessageLen] & "..."

proc parseSarif(source: SastSource): seq[SastResult] =
  for run in source.doc["runs"].getElems():
    for invocation in run{"invocations"}.getElems():
      if invocation{"executionSuccessful"} != nil and
         not invocation{"executionSuccessful"}.getBool(true):
        raise newException(ValueError, source.tool & " reported an unsuccessful scan")
    var rules = initTable[string, JsonNode]()
    let ruleList = run{"tool", "driver", "rules"}.getElems()
    for rule in ruleList:
      rules[rule{"id"}.getStr()] = rule
    for item in run{"results"}.getElems():
      # in-source suppressions, e.g. `# nosemgrep`
      if len(item{"suppressions"}.getElems()) > 0:
        continue
      var ruleId = item{"ruleId"}.getStr()
      if ruleId == "":
        ruleId = item{"rule", "id"}.getStr()
      if ruleId == "":
        let index = item{"ruleIndex"}.getInt(-1)
        if index >= 0 and index < len(ruleList):
          ruleId = ruleList[index]{"id"}.getStr()
      let
        rule     = rules.getOrDefault(ruleId, newJObject())
        location = item{"locations"}.getElems()
        physical = if len(location) > 0: location[0]{"physicalLocation"} else: nil
      let path = source.resultPath(physical{"artifactLocation", "uri"}.getStr())
      if path.isNone():
        continue
      var r = SastResult(
        tool:    source.tool,
        ruleId:  ruleId,
        path:    path.get(),
        line:    physical{"region", "startLine"}.getInt(),
        message: item{"message", "text"}.getStr(),
      )
      let score = rule{"properties", "security-severity"}
      var scored = false
      if score != nil:
        try:
          r.severity = securitySeveritySeverity(score.parseScore())
          scored = true
        except ValueError:
          discard
      if not scored:
        let level = item{"level"}.getStr(rule{"defaultConfiguration", "level"}.getStr())
        r.severity = sarifLevelSeverity(level)
      # semgrep encodes rule metadata as tags: CWE ids, `OWASP-...`,
      # `<LEVEL> CONFIDENCE`, `security` (whenever the rule has a CWE) and
      # the rule's own `metadata.tags`
      for tag in rule{"properties", "tags"}.strings():
        let upper = tag.toUpperAscii()
        if upper.startsWith("CWE-"):
          r.cwes.add(tag.cweId())
        elif upper.endsWith(" CONFIDENCE"):
          r.confidence = tag[0 ..< len(tag) - len(" CONFIDENCE")].strip().toLowerAscii()
        elif not upper.startsWith("OWASP-"):
          r.categories.add(tag.toLowerAscii())
      result.add(r)

proc parseSemgrepJson(source: SastSource): seq[SastResult] =
  ## https://semgrep.dev/docs/semgrep-appsec-platform/json-and-sarif
  for item in source.doc["results"].getElems():
    let extra = item{"extra"}
    if extra{"is_ignored"}.getBool(false):
      continue
    let path = source.resultPath(item{"path"}.getStr())
    if path.isNone():
      continue
    let metadata = extra{"metadata"}
    var r = SastResult(
      tool:       source.tool,
      ruleId:     item{"check_id"}.getStr(),
      path:       path.get(),
      line:       item{"start", "line"}.getInt(),
      severity:   semgrepSeverity(extra{"severity"}.getStr()),
      confidence: metadata{"confidence"}.getStr().toLowerAscii(),
      message:    extra{"message"}.getStr(),
    )
    for category in metadata{"category"}.strings():
      r.categories.add(category.toLowerAscii())
    # semgrep tags SARIF output with `security` whenever a rule has a CWE;
    # do the same so `categories` behaves alike for both formats
    for cwe in metadata{"cwe"}.strings():
      r.cwes.add(cwe.cweId())
      if "security" notin r.categories:
        r.categories.add("security")
    for subcategory in metadata{"subcategory"}.strings():
      r.subcategories.add(subcategory.toLowerAscii())
    result.add(r)

proc parseSastSource*(source: SastSource): seq[SastResult] =
  ## raises ValueError for output this rule cannot interpret
  if source.doc == nil or source.doc.kind != JObject:
    raise newException(ValueError, source.tool & " output is not a JSON object")
  if source.doc{"runs"} != nil and source.doc{"runs"}.kind == JArray:
    return source.parseSarif()
  if source.doc{"results"} != nil and source.doc{"results"}.kind == JArray:
    return source.parseSemgrepJson()
  raise newException(ValueError, source.tool & " output is neither SARIF nor semgrep JSON")

proc isAudit*(r: SastResult): bool =
  if len(r.subcategories) > 0:
    return "audit" in r.subcategories
  # SARIF drops `metadata.subcategory`; registry rule ids often, but not
  # always, carry it as a segment, e.g. `python.lang.security.audit.eval-detected`
  "audit" in r.ruleId.toLowerAscii().split('.')

proc matchesAny(patterns: seq[string], value: string): bool =
  for pattern in patterns:
    if globMatch(pattern, value):
      return true

proc counts*(settings: SastConfig, r: SastResult): bool =
  ## whether a result is a violation under `settings`
  if severities.rank(r.severity) < severities.rank(settings.minSeverity):
    return false
  if settings.minConfidence != "" and settings.minConfidence != "low":
    # rules without a confidence make no claim, so they only count when
    # every confidence does
    if confidences.rank(r.confidence) < confidences.rank(settings.minConfidence):
      return false
  if len(settings.categories) > 0:
    var found = false
    for category in settings.categories:
      if category.toLowerAscii() in r.categories:
        found = true
    if not found:
      return false
  if len(settings.cwes) > 0:
    var found = false
    for cwe in r.cwes:
      for pattern in settings.cwes:
        if globMatch(pattern.toUpperAscii(), cwe):
          found = true
    if not found:
      return false
  if not settings.includeAudit and r.isAudit():
    return false
  if settings.ignoreRules.matchesAny(r.ruleId):
    return false
  if settings.ignorePaths.matchesAny(r.path):
    return false
  return true

proc location(r: SastResult): string =
  if r.path == "":
    return ""
  if r.line > 0:
    return r.path & ":" & $r.line
  r.path

proc semgrepScanErrors(source: SastSource): seq[PolicyFinding] =
  # Scan failures are independent of matches. Keep valid matches while
  # allowing on_error to decide whether incomplete analysis blocks.
  if (source.doc{"runs"} != nil and source.doc{"runs"}.kind == JArray) or
     source.doc{"results"} == nil:
    return
  let errors = source.doc{"errors"}
  if errors == nil:
    return
  var incomplete = false
  var location = ""
  if errors.kind != JArray:
    incomplete = true
  else:
    for error in errors.getElems():
      if error.kind != JObject:
        incomplete = true
        continue
      # Semgrep scan errors use warn/error. Ignore informational diagnostics.
      if error{"level"}.getStr().toLowerAscii() in ["info", "debug"]:
        continue
      let path = error{"path"}.getStr()
      if path != "":
        let relative = source.resultPath(path)
        if relative.isNone():
          continue
        if location == "":
          location = relative.get()
      incomplete = true
  if incomplete:
    var reason = source.tool & " reported scan errors; SAST analysis is incomplete"
    if source.image != "":
      reason &= " (mark of " & source.image & ")"
    result.add(newSubjectFinding(ruleName, "error", source.tool, reason, location = location))

proc check*(settings: SastConfig, sources: seq[SastSource]): seq[PolicyFinding] =
  var counted: seq[(SastSource, SastResult)]
  for source in sources:
    var results: seq[SastResult]
    try:
      results = source.parseSastSource()
    except CatchableError:
      var reason = "could not read SAST results: " & getCurrentExceptionMsg()
      if source.image != "":
        reason &= " (mark of " & source.image & ")"
      result.add(newSubjectFinding(ruleName, "error", source.tool, reason))
      continue
    result.add(source.semgrepScanErrors())
    for r in results:
      if settings.counts(r):
        counted.add((source, r))
  if len(counted) <= settings.maxFindings:
    return
  counted.sort(proc(a, b: (SastSource, SastResult)): int =
    -cmp(severities.rank(a[1].severity), severities.rank(b[1].severity)))
  var violations: seq[PolicyFinding]
  for (source, r) in counted:
    var reason = r.severity & " " & r.tool & " finding"
    if r.message != "":
      reason &= ": " & r.message.truncate()
    if source.image != "":
      reason &= " (in " & source.image & ")"
    if settings.message != "":
      reason &= ". " & settings.message
    violations.add(newSubjectFinding(ruleName, "violation", r.ruleId, reason,
                                     location = r.location(), severity = r.severity))
  result.add(violations.capFindings(ruleName, maxReportedFindings, "SAST findings"))

proc sources(outputs: seq[ToolOutput], dir = ""): seq[SastSource] =
  for output in outputs:
    var source = SastSource(tool: output.tool, doc: output.value, image: output.image, dir: dir)
    if output.root != "":
      source.roots = @[output.root]
    result.add(source)

proc collectSources*(input: PolicyInput, runTools, toolsRan: bool): tuple[sources: seq[SastSource], errors: seq[PolicyFinding]] =
  ## `toolsRan`: `run_sast_tools` already ran the tools before policies
  if input.command == "push":
    # nothing to scan, so only results recorded in the image's mark count
    let pushed = input.pushedToolOutputs(ruleName, "SAST")
    return (pushed.outputs.sources(), pushed.errors)
  var host: seq[ToolOutput]
  try:
    host = input.host.toolOutputs("SAST")
  except CatchableError:
    result.errors.add(newSubjectFinding(ruleName, "error", "sast",
                                        "could not read SAST results: " & getCurrentExceptionMsg()))
    return
  if len(host) == 0 and toolsRan:
    result.errors.add(newSubjectFinding(ruleName, "error", "sast",
                                        "SAST tools produced no results, see the chalk logs"))
    return
  let request = ToolRequest(
    rule:         ruleName,
    kind:         "sast",
    key:          "SAST",
    what:         "SAST results",
    runTools:     runTools,
    notCollected: "SAST results were not collected; enable run_sast_tools or policy.sast.run_tools",
  )
  let outputs = input.contextToolOutputs(request, host)
  result.errors = outputs.errors
  for context in outputs.contexts:
    result.sources.add(context.outputs.sources(context.dir))

proc loadSastConfig*(): Option[SastConfig] =
  if not policyBoolSetting([ruleName, "enabled"], false):
    return none(SastConfig)
  let settings = SastConfig(
    minSeverity:   policyStringSetting([ruleName, "min_severity"], "high"),
    minConfidence: policyStringSetting([ruleName, "min_confidence"], "low"),
    categories:    policyStringsSetting([ruleName, "categories"]),
    cwes:          policyStringsSetting([ruleName, "cwes"]),
    ignoreRules:   policyStringsSetting([ruleName, "ignore_rules"]),
    ignorePaths:   policyStringsSetting([ruleName, "ignore_paths"]),
    includeAudit:  policyBoolSetting([ruleName, "include_audit"], true),
    maxFindings:   policyIntSetting([ruleName, "max_findings"], 0),
    runTools:      policyBoolSetting([ruleName, "run_tools"], true),
    message:       policyStringSetting([ruleName, "message"], ""),
  )
  if settings.minSeverity notin severities:
    raise newException(ValueError, "policy.sast.min_severity must be one of " & $severities)
  if settings.minConfidence notin confidences:
    raise newException(ValueError, "policy.sast.min_confidence must be one of " & $confidences)
  if settings.maxFindings < 0:
    raise newException(ValueError, "policy.sast.max_findings must not be negative")
  return some(settings)

const
  sastJsonFields = [
    PolicyJsonField(name: "enabled",        kind: JBool),
    PolicyJsonField(name: "min_severity",   kind: JString, choices: @severities),
    PolicyJsonField(name: "min_confidence", kind: JString, choices: @confidences),
    PolicyJsonField(name: "categories",     kind: JArray),
    PolicyJsonField(name: "cwes",           kind: JArray),
    PolicyJsonField(name: "ignore_rules",   kind: JArray),
    PolicyJsonField(name: "ignore_paths",   kind: JArray),
    PolicyJsonField(name: "include_audit",  kind: JBool),
    PolicyJsonField(name: "max_findings",   kind: JInt),
    PolicyJsonField(name: "run_tools",      kind: JBool),
    PolicyJsonField(name: "message",        kind: JString),
  ]

proc validateSastJson(node: JsonNode, path: string) =
  node.validateFields(sastJsonFields, path)
  for field in ["categories", "cwes", "ignore_rules", "ignore_paths"]:
    for entry in node{field}.getElems():
      if entry.kind != JString:
        raise newException(ValueError, path & field & " entries must be strings")
  if node{"max_findings"}.getInt(0) < 0:
    raise newException(ValueError, path & "max_findings must not be negative")

registerPolicyJsonSection(ruleName, validateSastJson)

var loaded: SastConfig

proc loadSast(): bool =
  let settings = loadSastConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome()

proc checkSast(input: PolicyInput): seq[PolicyFinding] =
  let (sources, errors) = input.collectSources(
    loaded.runTools,
    attrGetOpt[bool]("run_sast_tools").get(false),
  )
  result = errors
  result.add(loaded.check(sources))

proc sastHint(): PolicyHint =
  # without a message the generic "use an allowed image" hint would mislead
  if loaded.message != "":
    result = PolicyHint(rule: ruleName, message: loaded.message)

proc loadSastRule*() =
  newPolicyInputRule(ruleName, loadSast, checkSast, hint = sastHint)
