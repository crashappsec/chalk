##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.vulnerabilities`: block pull requests that add dependencies with
## known vulnerabilities, from GitHub's dependency review of the commits the
## GitHub Actions job compares, as actions/dependency-review-action does.
## See docs/design-build-policy.md.

import std/[
  algorithm,
  json,
  os,
  sequtils,
  strutils,
  tables,
]
import "../.."/[
  types,
]
import ".."/[
  api,
  configuration,
  dockerignore,
  github,
  helpers,
  purl,
]
import "."/[
  golden_images,
  packages,
]

const
  ruleName*    = "dependency_review"
  sectionName* = "vulnerabilities"
  severities*  = ["low", "medium", "high", "critical"]
  scopes*      = ["runtime", "development", "unknown"]
  defaultScopes = ["runtime"]
  # keeps reports and the job summary bounded
  maxReportedFindings = 100

type
  VulnerabilitiesConfig* = object
    minSeverity*:      string # one of `severities`
    scopes*:           seq[string]
    ignoreAdvisories*: seq[string] # lowercase globs, as GHSA ids are compared
    ignorePackages*:   seq[PurlPattern]
    ignorePaths*:      seq[string]
    maxFindings*:      int
    message*:          string
    events*:           seq[string]
    contextOnly*:      bool

  ## manifests of a build context, within the repository
  ReviewContext* = object
    path*:   string # repository-relative directory, empty for the root
    ignore*: DockerIgnore

proc normalizeSeverity*(value: string): string =
  ## GitHub rates advisories `moderate` where chalk says `medium`
  result = value.strip().toLowerAscii()
  if result == "moderate":
    result = "medium"

proc rank(value: string): int =
  severities.find(value.normalizeSeverity())

proc sortRank(value: string): int =
  ## a rating chalk does not know counts (see `counts`), so it is kept
  ## ahead of known ones when findings are capped
  result = value.rank()
  if result < 0:
    result = len(severities)

proc defaulted(values: seq[string], default: openArray[string]): seq[string] =
  if len(values) == 0: @default else: values

proc parseIgnorePackages(values: seq[string], path: string): seq[PurlPattern] =
  for value in values:
    try:
      result.add(parsePackagePattern(value))
    except ValueError:
      raise newException(ValueError, path & "ignore_packages: invalid entry " &
                                     escapeJson(value) & ": " & getCurrentExceptionMsg())

proc validate(settings: VulnerabilitiesConfig) =
  let path = "policy." & sectionName & "."
  if settings.minSeverity notin severities:
    raise newException(ValueError, path & "min_severity must be one of " & $severities &
                                   " or \"moderate\"")
  for scope in settings.scopes:
    if scope notin scopes:
      raise newException(ValueError, path & "scopes entries must be one of " & $scopes)
  for event in settings.events:
    if event notin reviewEvents:
      raise newException(ValueError, path & "dependency_review.events entries must be one of " &
                                     $reviewEvents)
  if settings.maxFindings < 0:
    raise newException(ValueError, path & "max_findings must not be negative")

proc loadVulnerabilitiesConfig*(): Option[VulnerabilitiesConfig] =
  if not policyBoolSetting([sectionName, "enabled"], false):
    return none(VulnerabilitiesConfig)
  var settings = VulnerabilitiesConfig(
    minSeverity:      policyStringSetting([sectionName, "min_severity"], "high").normalizeSeverity(),
    scopes:           policyStringsSetting([sectionName, "scopes"]).defaulted(defaultScopes),
    ignoreAdvisories: policyStringsSetting([sectionName, "ignore_advisories"]).mapIt(it.toLowerAscii()),
    ignorePaths:      policyStringsSetting([sectionName, "ignore_paths"]),
    maxFindings:      policyIntSetting([sectionName, "max_findings"], 0),
    message:          policyStringSetting([sectionName, "message"], ""),
    events:           policyStringsSetting([sectionName, "dependency_review", "events"])
                        .defaulted(defaultReviewEvents),
    contextOnly:      policyBoolSetting([sectionName, "dependency_review", "context_only"], true),
  )
  settings.ignorePackages = policyStringsSetting([sectionName, "ignore_packages"])
    .parseIgnorePackages("policy." & sectionName & ".")
  settings.validate()
  return some(settings)

proc matchesAny(patterns: seq[string], value: string): bool =
  for pattern in patterns:
    if globMatch(pattern, value):
      return true

proc inContext(contexts: seq[ReviewContext], manifest: string): bool =
  ## whether docker sends `manifest` of one of `contexts` to the build
  let manifest = manifest.strip(trailing = false, chars = {'/'})
  for context in contexts:
    var relative = manifest
    if context.path != "":
      if not manifest.startsWith(context.path & "/"):
        continue
      relative = manifest[len(context.path) + 1 .. ^1]
    if not context.ignore.isIgnored(relative):
      return true
  return false

proc subject(change: DependencyChange): string =
  if change.packageUrl != "":
    return change.packageUrl
  result = change.ecosystem & "/" & change.name
  if change.version != "":
    result &= "@" & change.version

proc isIgnoredPackage(settings: VulnerabilitiesConfig, change: DependencyChange): bool =
  # a version the pattern cannot compare is not ignored, so it still counts
  settings.ignorePackages.firstMatch(change.subject()).result == pmMatch

proc counts*(settings: VulnerabilitiesConfig, change: DependencyChange,
             vulnerability: DependencyVulnerability): bool =
  ## whether `vulnerability` of `change` is a violation under `settings`;
  ## see `check` for the build context
  let severity = vulnerability.severity.rank()
  change.changeType == "added" and
    change.scope.toLowerAscii() in settings.scopes and
    # a rating chalk does not know, e.g. a level GitHub adds later, always
    # counts rather than silently passing
    (severity < 0 or severity >= settings.minSeverity.rank()) and
    # GitHub writes ids `GHSA-` plus lowercase; globs are matched case-insensitively
    not settings.ignoreAdvisories.matchesAny(vulnerability.ghsaId.toLowerAscii()) and
    not settings.ignorePaths.matchesAny(change.manifest) and
    not settings.isIgnoredPackage(change)

type Hit = object
  change:        DependencyChange
  vulnerability: DependencyVulnerability
  manifests:     seq[string]

proc check*(settings: VulnerabilitiesConfig, review: DependencyReview,
            contexts: Option[seq[ReviewContext]] = none(seq[ReviewContext])): seq[PolicyFinding] =
  ## Findings of a completed review, one per package and advisory. With
  ## `contexts`, only manifests docker sends to the build count.
  var hits = initOrderedTable[string, Hit]()
  for change in review.changes:
    if contexts.isSome() and not contexts.get().inContext(change.manifest):
      continue
    for vulnerability in change.vulnerabilities:
      if not settings.counts(change, vulnerability):
        continue
      let key = change.subject() & "\0" & vulnerability.ghsaId
      if key in hits:
        if change.manifest notin hits[key].manifests:
          hits[key].manifests.add(change.manifest)
      else:
        hits[key] = Hit(change: change, vulnerability: vulnerability,
                        manifests: @[change.manifest])
  if len(hits) <= settings.maxFindings:
    return
  var ordered: seq[Hit]
  for hit in hits.values():
    ordered.add(hit)
  ordered.sort(proc(a, b: Hit): int =
    result = -cmp(a.vulnerability.severity.sortRank(), b.vulnerability.severity.sortRank())
    if result == 0:
      result = cmp(a.change.subject(), b.change.subject()))
  var violations: seq[PolicyFinding]
  for hit in ordered:
    let
      v        = hit.vulnerability
      severity = v.severity.normalizeSeverity()
    var reason = severity & " " & v.ghsaId
    if v.summary != "":
      reason &= ": " & v.summary.strip()
    if v.url != "":
      reason &= " (" & v.url & ")"
    if len(hit.manifests) > 1:
      reason &= "; also added in " & hit.manifests[1 .. ^1].join(", ")
    if settings.message != "":
      reason &= ". " & settings.message
    violations.add(newSubjectFinding(ruleName, "violation", hit.change.subject(), reason,
                                     location = hit.manifests[0], severity = severity))
  violations.capFindings(ruleName, maxReportedFindings, "vulnerable dependencies")

proc reviewContexts*(input: PolicyInput, refs: ReviewRefs): Option[seq[ReviewContext]] =
  ## The build contexts within the repository, with their `.dockerignore`;
  ## none, to review every manifest, when none of them is part of it, e.g.
  ## a remote context or a checkout of another repository, so a vulnerable
  ## dependency is never let through for not being located
  if len(input.contextErrors) > 0:
    warnOnce("policy: dependency review: some build contexts could not be located, so " &
             refs.repo & "'s dependency changes are reviewed outside them too")
    return none(seq[ReviewContext])
  if input.repoPath == nil:
    return none(seq[ReviewContext])
  var contexts: seq[ReviewContext]
  for dir in input.contextDirs:
    var path: Option[string]
    try:
      path = input.repoPath(dir)
    except CatchableError:
      trace("policy: could not locate " & dir & " in " & refs.repo & ": " & getCurrentExceptionMsg())
    if path.isNone():
      continue
    var ignore: DockerIgnore
    try:
      ignore = loadDockerignore(dir, input.mainContextDockerfile(dir))
    except CatchableError:
      # docker cannot read it either; every manifest of the context counts
      trace("policy: could not read the .dockerignore of " & dir & ": " & getCurrentExceptionMsg())
    contexts.add(ReviewContext(path: path.get().strip(chars = {'/'}), ignore: ignore))
  if len(contexts) == 0:
    warnOnce("policy: dependency review: the build contexts are not part of " & refs.repo &
             "'s work tree, so its dependency changes are reviewed outside them too")
    return none(seq[ReviewContext])
  return some(contexts)

proc checkReview*(settings: VulnerabilitiesConfig, input: PolicyInput): seq[PolicyFinding] =
  # Only builds are reviewed: a push has no build context to narrow the
  # review to, and what its images were built from is not known reliably
  # (an unsigned mark, inherited through FROM).
  if input.command != "build":
    trace("policy: dependency review only runs on docker build")
    return
  var found: Option[ReviewRefs]
  try:
    found = reviewRefs(settings.events)
  except ValueError:
    return @[newSubjectFinding(ruleName, "error", getEnv("GITHUB_REPOSITORY"),
                               "could not determine the commits to review: " &
                               getCurrentExceptionMsg())]
  if found.isNone():
    return
  let
    refs   = found.get()
    review = refs.dependencyReview()
  case review.status
  of rsUnavailable:
    let message = "Dependency review of " & refs.repo & " is unavailable, so policy." & sectionName &
                  " cannot check the dependencies this " & refs.event.replace('_', ' ') &
                  " adds for vulnerabilities: " & review.reason
    warnOnce("policy: " & message)
    addPolicyNotice(ruleName, message)
    return
  of rsFailed:
    return @[newSubjectFinding(ruleName, "error", refs.repo, "dependency review failed: " & review.reason)]
  of rsReviewed:
    discard
  if review.snapshotWarnings != "":
    # e.g. a dependency submission for the head commit still pending
    warnOnce("policy: GitHub's dependency graph may be incomplete for " & $refs & ": " &
             review.snapshotWarnings.strip())
  let contexts =
    if settings.contextOnly: input.reviewContexts(refs)
    else: none(seq[ReviewContext])
  settings.check(review, contexts)

const
  dependencyReviewJsonFields = [
    PolicyJsonField(name: "events",       kind: JArray),
    PolicyJsonField(name: "context_only", kind: JBool),
  ]
  vulnerabilitiesJsonFields = [
    PolicyJsonField(name: "enabled",           kind: JBool),
    PolicyJsonField(name: "min_severity",      kind: JString,
                    choices: @["low", "moderate", "medium", "high", "critical"]),
    PolicyJsonField(name: "scopes",            kind: JArray),
    PolicyJsonField(name: "ignore_advisories", kind: JArray),
    PolicyJsonField(name: "ignore_packages",   kind: JArray),
    PolicyJsonField(name: "ignore_paths",      kind: JArray),
    PolicyJsonField(name: "max_findings",      kind: JInt),
    PolicyJsonField(name: "message",           kind: JString),
    PolicyJsonField(name: "dependency_review", kind: JObject),
  ]

proc strings(node: JsonNode, path: string): seq[string] =
  for entry in node.getElems():
    if entry.kind != JString:
      raise newException(ValueError, path & " entries must be strings")
    result.add(entry.getStr())

proc validateVulnerabilitiesJson(node: JsonNode, path: string) =
  node.validateFields(vulnerabilitiesJsonFields, path)
  let review = node{"dependency_review"}
  if review != nil:
    review.validateFields(dependencyReviewJsonFields, path & "dependency_review.")
  for scope in node{"scopes"}.strings(path & "scopes"):
    if scope notin scopes:
      raise newException(ValueError, path & "scopes entries must be one of " & $scopes)
  discard node{"ignore_advisories"}.strings(path & "ignore_advisories")
  discard node{"ignore_paths"}.strings(path & "ignore_paths")
  discard node{"ignore_packages"}.strings(path & "ignore_packages").parseIgnorePackages(path)
  if node{"max_findings"}.getInt(0) < 0:
    raise newException(ValueError, path & "max_findings must not be negative")
  for event in review{"events"}.strings(path & "dependency_review.events"):
    if event notin reviewEvents:
      raise newException(ValueError, path & "dependency_review.events entries must be one of " &
                                     $reviewEvents)

registerPolicyJsonSection(sectionName, validateVulnerabilitiesJson)

var loaded: VulnerabilitiesConfig

proc loadDependencyReview(): bool =
  let settings = loadVulnerabilitiesConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome() and getEnv("GITHUB_ACTIONS") == "true" and
         getEnv("GITHUB_EVENT_NAME") in loaded.events

proc checkDependencyReview(input: PolicyInput): seq[PolicyFinding] =
  loaded.checkReview(input)

proc dependencyReviewHint(): PolicyHint =
  # without a message the generic "use an allowed image" hint would mislead
  if loaded.message != "":
    result = PolicyHint(rule: ruleName, message: loaded.message)

proc loadDependencyReviewRule*() =
  # Contexts narrow the review when available; otherwise review the repository.
  newPolicyInputRule(ruleName, loadDependencyReview, checkDependencyReview,
                     usesContext = true, hint = dependencyReviewHint)
