##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Build policy outcome as Markdown in the GitHub Actions job summary
## (`GITHUB_STEP_SUMMARY`). Writing it must never affect the docker command.
## https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary

import std/[os, strutils, unicode]
import ".."/[
  config,
  types,
]
import ./state

const
  maxPolicyRows*  = 50
  maxFindingRows* = 50
  maxAllowed*     = 10
  maxCellLen*     = 200
  # GitHub rejects a step's summary above 1 MiB, for all sections combined
  maxSummaryBytes = 1024 * 1024

type PendingSummary = object
  policies: seq[PolicyResult]
  build:    ChalkDict

var pendingSummaries: seq[PendingSummary]

proc truncate(value: string, maxLen: int): string =
  result = value.multiReplace(("\r\n", " "), ("\n", " "), ("\r", " ")).strip()
  if result.runeLen() > maxLen:
    result = result.runeSubStr(0, maxLen - 1) & "…"

proc mdText*(value: string, maxLen = maxCellLen): string =
  ## Single line of text: truncated, with `|` and HTML escaped so a value
  ## cannot break a table or inject markup.
  result = value.truncate(maxLen)
  if result == "":
    return "-"
  # backslashes first, or `a\|b` would become `a\\|b`, which can end the cell
  result = result.multiReplace(("\\", "\\\\"), ("&", "&amp;"), ("<", "&lt;"),
                               (">", "&gt;"), ("|", "\\|"))

proc mdCode*(value: string, maxLen = maxCellLen, inTable = true): string =
  ## Inline code. Entities and backslash escapes are not decoded in code
  ## spans, so only what could end the span or the table cell is changed;
  ## GFM strips the `\` of `\|` in table cells, code spans included.
  var text = value.truncate(maxLen).replace("`", "'")
  if inTable:
    text = text.replace("|", "\\|")
  "`" & text & "`"

proc plural(n: int, word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc buildCommand(build: ChalkDict): string =
  if build != nil and "command" in build:
    try:
      return unpack[string](build["command"])
    except CatchableError:
      discard
  "docker"

proc buildTags(build: ChalkDict): seq[string] =
  if build != nil and "tags" in build:
    try:
      return unpack[seq[string]](build["tags"])
    except CatchableError:
      discard

proc policyName(id: string): string =
  if id == "": "(unnamed)" else: id

proc policyRefs(ids: seq[string], capital = false): string =
  ## e.g. policy `a`, policies `a`, `b`; empty when no policy has an id
  var named: seq[string]
  for id in ids:
    if id != "" and mdCode(id, 100, inTable = false) notin named:
      named.add(mdCode(id, 100, inTable = false))
  if len(named) == 0:
    return (if capital: "The policy" else: "the policy")
  result = (if len(named) == 1: "policy " else: "policies ") & named.join(", ")
  if capital:
    result[0] = result[0].toUpperAscii()

proc withoutQuery*(location: string): string =
  ## a presigned URL carries its credentials in the query string
  result = location.split('?', 1)[0].split('#', 1)[0]
  let scheme = result.find("://")
  if scheme >= 0:
    let
      start = scheme + 3
      slash = result.find('/', start)
      authority = if slash < 0: result[start .. ^1] else: result[start ..< slash]
      at = authority.rfind('@')
    if at >= 0:
      result = result[0 ..< start] & result[start + at + 1 .. ^1]

proc shortDigest(digest: string): string =
  # chalk records some digests as bare sha256 hex
  var (algo, hex) = ("sha256", digest)
  let colon = digest.find(':')
  if colon >= 0:
    (algo, hex) = (digest[0 ..< colon], digest[colon + 1 .. ^1])
  if len(hex) > 12:
    hex = hex[0 ..< 12] & "…"
  algo & ":" & hex

proc imageRef(f: PolicyFinding): string =
  let at = f.image.find("@")
  if at >= 0:
    return f.image[0 ..< at] & "@" & shortDigest(f.image[at + 1 .. ^1])
  if f.image != "" and f.digest != "":
    return f.image & "@" & shortDigest(f.digest)
  f.image

proc subjectRef(f: PolicyFinding): string =
  if f.image != "":
    return mdCode(f.imageRef())
  if f.subject == "":
    return "-"
  result = mdCode(f.subject)
  if f.location != "":
    result &= " " & mdText(f.location)

proc usedAs(f: PolicyFinding): string =
  result =
    case f.source
    of "from":       "FROM"
    of "copy_from":  "COPY --from"
    of "mount_from": "RUN --mount from"
    else:            f.source
  # unnamed stages are numbered
  if f.stage != "" and not f.stage.allCharsInSet(Digits):
    result &= " (stage " & f.stage & ")"

proc distinctImages(findings: seq[PolicyFinding]): int =
  var seen: seq[string]
  for f in findings:
    if f.image != "" and f.image notin seen:
      seen.add(f.image)
  len(seen)

proc hintFor(p: PolicyResult, rule: string): PolicyHint =
  for h in p.hints:
    if h.rule == rule:
      return h

proc why(p: PolicyResult, f: PolicyFinding): string =
  let message = p.hintFor(f.rule).message
  if f.kind == "violation" and message != "":
    return message
  f.reason

proc violationPhrase(findings: seq[PolicyFinding]): string =
  var
    n      = distinctImages(findings)
    golden = true
  for f in findings:
    if f.rule != "golden_images":
      golden = false
  if n == 0:
    n = len(findings)
  if golden:
    if n == 1: "1 image is not an approved golden image"
    else: $n & " images are not approved golden images"
  else:
    if n == 1: "1 image violates build policy"
    else: $n & " images violate build policy"

proc sentence(text: string): string =
  result = text.strip()
  if result != "" and result[^1] notin {'.', '!', '?'}:
    result &= "."

proc callout(policies: seq[PolicyResult], command: string): seq[string] =
  var
    blocked, violating, erroring: seq[PolicyResult]
    blockedFindings, violations, errors: seq[PolicyFinding]
  for p in policies:
    case p.result
    of "blocked":
      blocked.add(p)
      blockedFindings.add(p.findings)
    of "violation":
      violating.add(p)
      for f in p.findings:
        if f.kind == "violation": violations.add(f)
    of "error":
      erroring.add(p)
      errors.add(p.findings)
    else: discard
  let verb = if command == "push": "pushing" else: "building"
  if len(blocked) > 0:
    var ids: seq[string]
    for p in blocked: ids.add(p.id)
    var blocking: seq[PolicyFinding]
    for f in blockedFindings:
      if f.kind == "violation": blocking.add(f)
    let phrase =
      if len(blocking) > 0: violationPhrase(blocking)
      else:
        let n = distinctImages(blockedFindings)
        (if n > 0: plural(n, "image") & " could not be evaluated"
         else: "the policy could not be evaluated") & " and on_error=block"
    var refs = policyRefs(ids)
    refs = (if refs == "the policy": "" else: refs & ", ") & "enforce"
    return @["> [!CAUTION]",
             "> **Blocked** — `docker " & mdText(command, 20) & "` stopped before " &
             verb & ": " & phrase & " (" & refs & ")."]
  if len(violating) > 0:
    var ids: seq[string]
    for p in violating: ids.add(p.id)
    let
      refs = policyRefs(ids, capital = true)
      be   = if refs.startsWith("Policies"): "are" else: "is"
    return @["> [!WARNING]",
             "> **Would be blocked under enforce** — " & violationPhrase(violations) & ". " &
             refs & " " & be & " in audit mode, so the " & mdText(command, 20) & " continued."]
  if len(erroring) > 0:
    var
      ids: seq[string]
      allow = true
    for p in erroring:
      ids.add(p.id)
      if p.onError != "allow":
        allow = false
    let
      n      = distinctImages(errors)
      what   = if n > 0: " could not evaluate " & plural(n, "image") else: " could not be evaluated"
      reason = if allow: "on_error=allow" else: "audit mode"
    return @["> [!NOTE]",
             "> " & policyRefs(ids, capital = true) & what & "; " & reason &
             ", so the " & mdText(command, 20) & " continued."]
  var golden = false
  for p in policies:
    if p.hintFor("golden_images").rule != "":
      golden = true
  let checked = $len(policies) & (if len(policies) == 1: " policy" else: " policies")
  @["> [!TIP]",
    "> " & (if golden: "All base images are approved golden images"
            else: "All images passed the build policy") & " (" & checked & " checked)."]

proc howToFix(policies: seq[PolicyResult]): seq[string] =
  for p in policies:
    var rules: seq[string]
    for f in p.findings:
      if f.kind == "violation" and f.rule notin rules:
        rules.add(f.rule)
    if len(rules) == 0:
      continue
    var parts: seq[string]
    for rule in rules:
      let hint = p.hintFor(rule)
      if hint.rule == "":
        continue
      var part = if hint.message != "": mdText(hint.message.sentence(), 300)
                 else: "Use an allowed image."
      if len(hint.allowed) > 0:
        var shown: seq[string]
        for value in hint.allowed[0 ..< min(len(hint.allowed), maxAllowed)]:
          shown.add(mdCode(value, 100, inTable = false))
        part &= " Allowed: " & shown.join(", ")
        if len(hint.allowed) > maxAllowed:
          part &= ", +" & $(len(hint.allowed) - maxAllowed) & " more"
      parts.add(part)
    if len(parts) == 0:
      continue
    var line = parts.join(" ")
    if len(policies) > 1 and p.id != "":
      line = "(" & mdCode(p.id, 100, inTable = false) & ") " & line
    result.add("**How to fix:** " & line)
    result.add("")

proc whyThisMode(p: PolicyResult): string =
  if p.modeSource == "enforce_repos":
    return "enforce_repos match (" & mdCode(p.repo, 100) & ")"
  if p.hasEnforceRepos and p.repo == "":
    return "repo unknown → default mode"
  "default mode"

proc renderPolicySummary*(policies:        seq[PolicyResult],
                          build:           ChalkDict,
                          reportLocations: seq[string] = @[],
                          version          = ""): string =
  let
    command = buildCommand(build)
    tags    = buildTags(build)
  var lines = callout(policies, command)
  lines.add("")
  var heading = "#### Chalk build policy · docker " & mdText(command, 20)
  if len(tags) > 0:
    heading &= " · " & mdCode(tags[0], 150, inTable = false)
    if len(tags) > 1:
      heading &= " (+" & $(len(tags) - 1) & " more)"
  lines.add(heading)
  lines.add("")

  var findings: seq[(PolicyResult, PolicyFinding)]
  for p in policies:
    for f in p.findings:
      findings.add((p, f))
  if len(findings) > 0:
    var onlyImages = true
    for (_, f) in findings:
      if f.subject != "":
        onlyImages = false
    if onlyImages:
      lines.add("| Image | Used as | Policy | Why |")
    else:
      lines.add("| Subject | Used as | Policy | Why |")
    lines.add("| --- | --- | --- | --- |")
    for (p, f) in findings[0 ..< min(len(findings), maxFindingRows)]:
      let image = f.subjectRef()
      lines.add("| " & image & " | " & mdText(f.usedAs()) & " | " &
                mdText(policyName(f.policyId)) & " | " & mdText(p.why(f)) & " |")
    if len(findings) > maxFindingRows:
      lines.add("")
      lines.add("_" & $(len(findings) - maxFindingRows) &
                " more findings not shown, see the policy report._")
    lines.add("")
    lines.add(howToFix(policies))

  lines.add("<details><summary>Policy details</summary>")
  lines.add("")
  lines.add("| Policy | Mode | Why this mode | Result | Findings |")
  lines.add("| --- | --- | --- | --- | --- |")
  var repo = ""
  for i, p in policies:
    if p.hasEnforceRepos and repo == "":
      repo = if p.repo != "": p.repo else: "unknown"
    if i >= maxPolicyRows:
      continue
    lines.add("| " & mdText(policyName(p.id)) & " | " & mdText(p.effectiveMode) & " | " &
              p.whyThisMode() & " | " & mdText(p.result) & " | " & $len(p.findings) & " |")
  if len(policies) > maxPolicyRows:
    lines.add("")
    lines.add("_" & $(len(policies) - maxPolicyRows) & " more policies not shown._")
  lines.add("")
  if version != "":
    lines.add("- Chalk version: " & mdCode(version, 50, inTable = false))
  if repo != "":
    lines.add("- Repository: " & mdCode(repo, 200, inTable = false))
  for location in reportLocations:
    lines.add("- Policy report: " & mdCode(location.withoutQuery(), 500, inTable = false))
  lines.add("")
  lines.add("</details>")
  lines.join("\n") & "\n"

proc stepSummaryEnabled(): bool =
  getEnv("GITHUB_STEP_SUMMARY") != "" and
    attrGetOpt[bool]("policy.github_step_summary").get(true)

proc recordPolicySummary*(policies: seq[PolicyResult], build: ChalkDict) =
  ## Queues the outcome of one evaluation for `writePolicySummary`.
  try:
    if stepSummaryEnabled():
      pendingSummaries.add(PendingSummary(policies: policies, build: build))
  except CatchableError:
    warn("policy: could not prepare the GitHub step summary: " & getCurrentExceptionMsg())

proc appendStepSummary(path, markdown: string) =
  var size = 0'i64
  if fileExists(path):
    size = getFileSize(path)
  if size + len(markdown) > maxSummaryBytes:
    raise newException(ValueError, "it would exceed GitHub's 1 MiB step summary limit")
  var f: File
  if not open(f, path, fmAppend):
    raise newException(IOError, "cannot open " & path & " for appending")
  try:
    f.write(markdown)
  finally:
    f.close()

proc writePolicySummary*(reportLocations: seq[string] = @[]) =
  ## Appends every queued outcome to `GITHUB_STEP_SUMMARY`, at most once each.
  ## Errors are warnings: the summary never changes the command's outcome.
  if len(pendingSummaries) == 0:
    return
  let pending = pendingSummaries
  pendingSummaries = @[]
  try:
    let path = getEnv("GITHUB_STEP_SUMMARY")
    if path == "":
      return
    var markdown = ""
    # only the last evaluation's outcome is in the policy report
    for i, s in pending:
      let locations = if i == high(pending): reportLocations else: @[]
      markdown &= "\n" & renderPolicySummary(s.policies, s.build, locations,
                                              getChalkExeVersion())
    appendStepSummary(path, markdown)
    trace("policy: wrote GitHub step summary")
  except CatchableError:
    warn("policy: could not write the GitHub step summary: " & getCurrentExceptionMsg())
