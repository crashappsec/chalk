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
from std/unicode import runeLen, runeSubStr
import "../.."/[
  types,
]
import ".."/[
  api,
  configuration,
  dockerignore,
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
  # Rules detecting secrets interpolate the matched value into their message
  # (e.g. `$SECRET`), so reports and job summaries omit it for them
  secretCwes = ["CWE-798", "CWE-259", "CWE-321"]
  secretRuleWords = ["secret", "credential", "password", "passwd", "token",
                     "api-key", "api_key", "apikey", "private-key"]

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
    secret*:        bool # see `secretCwes`

  SastSource* = object
    ## one tool's output, e.g. `SAST.semgrep`
    tool*:  string
    doc*:   JsonNode
    roots*: seq[string] # directories the tool scanned
    image*: string      # pushed image whose mark recorded it, empty on build
    ## build context directory: results outside it are dropped and paths are
    ## relative to it; empty on push
    dir*:   string
    ## what docker leaves out of `dir`: results there are dropped too
    ignore*: DockerIgnore

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

proc contextFile(source: SastSource, path: string): Option[string] =
  ## `resultPath`, `none` too when docker does not send the file
  result = source.resultPath(path)
  if result.isSome() and source.ignore.isIgnored(result.get()):
    return none(string)

proc isSecretRule(ruleId: string, cwes, labels: seq[string]): bool =
  for cwe in cwes:
    if cwe in secretCwes:
      return true
  for label in labels:
    if "secret" in label.toLowerAscii():
      return true
  let id = ruleId.toLowerAscii()
  for word in secretRuleWords:
    if word in id:
      return true

proc truncate(s: string): string =
  let flat = s.strip().replace('\n', ' ')
  if flat.runeLen() <= maxMessageLen:
    return flat
  # by runes, so a multi-byte character is not cut into invalid UTF-8
  flat.runeSubStr(0, maxMessageLen) & "..."

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
      let path = source.contextFile(physical{"artifactLocation", "uri"}.getStr())
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
      # SARIF drops `metadata.technology`, e.g. `secrets`
      r.secret = isSecretRule(ruleId, r.cwes, r.categories)
      result.add(r)

proc parseSemgrepJson(source: SastSource): seq[SastResult] =
  ## https://semgrep.dev/docs/semgrep-appsec-platform/json-and-sarif
  for item in source.doc["results"].getElems():
    let extra = item{"extra"}
    if extra{"is_ignored"}.getBool(false):
      continue
    let path = source.contextFile(item{"path"}.getStr())
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
    r.secret = isSecretRule(r.ruleId, r.cwes,
                            r.categories & r.subcategories &
                            metadata{"technology"}.strings() & metadata{"tags"}.strings())
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

type ScanErrors = object
  found:     bool
  location:  string
  kinds:     seq[string]
  ambiguous: bool # see `isAmbiguousParse`

proc add(errors: var ScanErrors, source: SastSource, kind, path: string): bool {.discardable.} =
  ## whether the error counts
  if path != "":
    let relative = source.contextFile(path)
    # errors elsewhere in a monorepo, or in files docker does not send, do
    # not affect the build
    if relative.isNone():
      return false
    if errors.location == "":
      errors.location = relative.get()
  errors.found = true
  if kind != "" and kind notin errors.kinds:
    errors.kinds.add(kind)
  return true

proc semgrepJsonErrors(source: SastSource, errors: var ScanErrors) =
  let node = source.doc{"errors"}
  if node == nil:
    return
  if node.kind != JArray:
    errors.found = true
    return
  for error in node.getElems():
    if error.kind != JObject:
      errors.found = true
      continue
    # semgrep scan errors use warn/error, e.g. `Timeout` is a warning
    if error{"level"}.getStr().toLowerAscii() in ["info", "debug"]:
      continue
    let kind = error{"type"}
    let name =
      if kind != nil and kind.kind == JArray and len(kind) > 0: kind[0].getStr()
      else: kind.getStr()
    # `["PartialParsing", [<spans>]]`: only those spans were skipped, the
    # rest of the file was scanned. Routine on real codebases.
    if name == "PartialParsing":
      continue
    errors.add(source, name, error{"path"}.getStr())

proc messagePath(text, name: string): string =
  ## semgrep's SARIF notifications have no `locations`; their message starts
  ## with `<descriptor id> at line <path>:<line>:`
  let prefix = name & " at line "
  if name == "" or not text.startsWith(prefix):
    return ""
  let rest = text[len(prefix) .. ^1].splitLines()[0]
  for i, c in rest:
    if c != ':' or i == 0:
      continue
    var j = i + 1
    while j < len(rest) and rest[j] in Digits:
      inc(j)
    if j > i + 1 and (j == len(rest) or rest[j] == ':'):
      return rest[0 ..< i]
  return ""

proc isAmbiguousParse(name, level: string): bool =
  ## semgrep's SARIF names partial parses (only some spans of a file were
  ## skipped) `Syntax error` warnings, like files it could not parse at all
  name == "Syntax error" and level == "warning"

iterator sarifNotifications(source: SastSource, errors: var ScanErrors):
    tuple[name, level, path: string] =
  ## semgrep reports scan errors as `toolExecutionNotifications` while
  ## keeping `executionSuccessful` true; notes are skipped
  for run in source.doc["runs"].getElems():
    for invocation in run{"invocations"}.getElems():
      for field in ["toolExecutionNotifications", "toolConfigurationNotifications"]:
        let node = invocation{field}
        if node == nil:
          continue
        if node.kind != JArray:
          errors.found = true
          continue
        for notification in node.getElems():
          # https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html#_Toc34317857
          # a missing level defaults to "warning"
          let level = notification{"level"}.getStr("warning")
          if level notin ["error", "warning"]:
            continue
          let name = notification{"descriptor", "id"}.getStr()
          let locations = notification{"locations"}.getElems()
          let path =
            if len(locations) > 0:
              locations[0]{"physicalLocation", "artifactLocation", "uri"}.getStr()
            else:
              notification{"message", "text"}.getStr().messagePath(name)
          yield (name, level, path)

proc sarifErrors(source: SastSource, errors: var ScanErrors) =
  for (name, level, path) in source.sarifNotifications(errors):
    # a partial parse cannot be told apart from a file semgrep did not scan
    # at all, so either counts
    if errors.add(source, name, path) and isAmbiguousParse(name, level):
      errors.ambiguous = true

proc hasAmbiguousParse*(source: SastSource): bool =
  ## SARIF `Syntax error` warnings in files of the build context
  if source.doc == nil or source.doc{"runs"} == nil or source.doc{"runs"}.kind != JArray:
    return false
  var errors: ScanErrors
  for (name, level, path) in source.sarifNotifications(errors):
    if isAmbiguousParse(name, level) and (path == "" or source.contextFile(path).isSome()):
      return true

proc scanErrors(source: SastSource): seq[PolicyFinding] =
  ## Scan failures are independent of matches: valid matches are kept and
  ## on_error decides whether incomplete analysis blocks.
  var errors: ScanErrors
  if source.doc{"runs"} != nil and source.doc{"runs"}.kind == JArray:
    source.sarifErrors(errors)
  else:
    source.semgrepJsonErrors(errors)
  if not errors.found:
    return
  var reason = source.tool & " reported scan errors"
  if len(errors.kinds) > 0:
    reason &= " (" & errors.kinds.join(", ") & ")"
  reason &= "; SAST analysis is incomplete"
  if errors.ambiguous:
    reason &= " (SARIF does not tell partial parses apart from files not parsed at all; semgrep JSON does)"
  if source.image != "":
    reason &= " (mark of " & source.image & ")"
  result.add(newSubjectFinding(ruleName, "error", source.tool, reason, location = errors.location))

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
    result.add(source.scanErrors())
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
    if r.secret:
      reason &= " (message omitted, the rule detects secrets)"
    elif r.message != "":
      reason &= ": " & r.message.truncate()
    if source.image != "":
      reason &= " (in " & source.image & ")"
    if settings.message != "":
      reason &= ". " & settings.message
    violations.add(newSubjectFinding(ruleName, "violation", r.ruleId, reason,
                                     location = r.location(), severity = r.severity))
  result.add(violations.capFindings(ruleName, maxReportedFindings, "SAST findings"))

proc sources(outputs: seq[ToolOutput], dir = "", ignore = DockerIgnore()): seq[SastSource] =
  for output in outputs:
    var source = SastSource(tool: output.tool, doc: output.value, image: output.image,
                            dir: dir, ignore: ignore)
    if output.root != "":
      source.roots = @[output.root]
    result.add(source)

proc setStringAttr(fqn, value: string): bool =
  con4mRuntime.configState.attrSet(fqn, pack(value)).code == errOk

proc useSemgrepPolicyFlags(): seq[(string, string)] =
  ## For the policy's own scans: semgrep JSON, as SARIF names partial parses
  ## like files semgrep could not parse at all (see `isAmbiguousParse`), and
  ## `--no-git-ignore`, as docker sends git-ignored files unless
  ## `.dockerignore` leaves them out. Returns the values to restore.
  if con4mRuntime == nil: # unit tests
    return
  let format = attrGetOpt[string]("tool.semgrep.semgrep_format")
  if format.isSome() and setStringAttr("tool.semgrep.semgrep_format", "json"):
    result.add(("tool.semgrep.semgrep_format", format.get()))
  let flags = attrGetOpt[string]("tool.semgrep.semgrep_other_flags")
  if flags.isSome() and
     setStringAttr("tool.semgrep.semgrep_other_flags", flags.get() & " --no-git-ignore"):
    result.add(("tool.semgrep.semgrep_other_flags", flags.get()))

proc restoreAttrs(saved: seq[(string, string)]) =
  for (fqn, value) in saved:
    discard setStringAttr(fqn, value)

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
  # with `run_tools` the contexts are scanned on demand below instead
  if len(host) == 0 and toolsRan and not runTools:
    result.errors.add(newSubjectFinding(ruleName, "error", "sast",
                                        "SAST tools produced no results, see the chalk logs"))
    return
  var ignores = initTable[string, DockerIgnore]()
  for dir in input.contextDirs:
    try:
      ignores[dir] = loadDockerignore(dir, input.mainContextDockerfile(dir))
    except CatchableError:
      # docker cannot read it either; results are not filtered
      result.errors.add(newSubjectFinding(ruleName, "error", dir,
                                          "could not read the .dockerignore of the build context: " &
                                          getCurrentExceptionMsg()))
      ignores[dir] = DockerIgnore()
  if runTools:
    # The rule's own scans are unambiguous, so contexts with ambiguous SARIF
    # parse errors are scanned again rather than reported as unchecked
    var kept: seq[ToolOutput]
    for output in host:
      var ambiguous = false
      for dir in input.contextDirs:
        if output.root != "" and dir.isWithin(output.root) and
           @[output].sources(dir, ignores[dir])[0].hasAmbiguousParse():
          ambiguous = true
          break
      if ambiguous:
        trace("policy: " & output.tool & " SARIF has ambiguous parse errors, scanning the build contexts")
      else:
        kept.add(output)
    host = kept
  let request = ToolRequest(
    rule:         ruleName,
    kind:         "sast",
    key:          "SAST",
    what:         "SAST results",
    runTools:     runTools,
    notCollected: "SAST results were not collected; enable run_sast_tools or policy.sast.run_tools",
  )
  let saved = useSemgrepPolicyFlags()
  var outputs: ToolOutputs
  try:
    outputs = input.contextToolOutputs(request, host)
  finally:
    restoreAttrs(saved)
  result.errors.add(outputs.errors)
  for context in outputs.contexts:
    result.sources.add(context.outputs.sources(context.dir, ignores.getOrDefault(context.dir)))

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
    # read by the dependency_review rule
    PolicyJsonField(name: "dependency_review", kind: JBool),
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
  newPolicyInputRule(ruleName, loadSast, checkSast, requiresContext = true, hint = sastHint)
