##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## API for build policy rules. Each rule is a standalone module under
## `policy/rules/` that registers itself with `newPolicyRule` from its
## `load*Rule` proc (see `policy/rules.nim`). The engine evaluates every
## registered rule against the images a docker command references.
## Rules that need more than images (the build context, push targets or
## SBOM/SAST/secret scanner output) register with `newPolicyInputRule`.

import ".."/[
  types,
]
import ./state

export state

type
  PolicySubject* = object
    image*:   DockerImage # as referenced, used for matching
    raw*:     string      # as referenced, used for reporting
    digests*: seq[string] # all known digests of the image
    stage*:   string
    source*:  string      # "from", "copy_from", "mount_from", or for
                          # `pullRefs` "syntax" or "cache_from"

  PolicyInput* = object
    subjects*: seq[PolicySubject]
    errors*:   seq[PolicyFinding] # subjects that could not be determined
    ## The collector failed before it could supply command/context data.
    collectionFailed*: bool
    command*:  string # "build" or "push"
    ## local build context directories, empty for push
    contextDirs*: seq[string]
    ## the main build context's entry of `contextDirs`, empty when the main
    ## context is not a local directory (named contexts may still be)
    mainContextDir*: string
    ## build contexts that are not local directories (stdin, URLs, git named
    ## contexts); the engine attributes them to rules that require the context
    contextErrors*: seq[PolicyFinding]
    ## build only: the path of a `contextDirs` entry within the git work tree
    ## of the CI job's repository, e.g. `services/api` (empty for its root),
    ## as repository-relative paths name it; none when the directory is not
    ## part of it. Nil when unknown.
    repoPath*: proc(dir: string): Option[string]
    ## Dockerfile of a build, so rules can honor `<Dockerfile>.dockerignore`;
    ## empty for push or when read from stdin
    dockerfilePath*: string
    ## the Dockerfile docker reads from stdin (`-f -`), which has no path
    stdinDockerfile*: string
    ## build only: images the build pulls that are not part of the built
    ## image, i.e. the BuildKit frontend (`# syntax=`, `BUILDKIT_SYNTAX`,
    ## source "syntax") and registry cache imports (`--cache-from`, source
    ## "cache_from"). Not in `subjects` so image rules such as
    ## `golden_images` do not check them; the `registries` rule does.
    pullRefs*: seq[PolicySubject]
    ## `pullRefs` that could not be determined, for rules that check them
    pullRefErrors*: seq[PolicyFinding]
    ## image references the command pushes, as given on the command line,
    ## including registry cache exports (`--cache-to type=registry,ref=`)
    pushTargets*: seq[string]
    ## chalk marks of the images `push` pushes, for those that are chalked
    pushMarks*: seq[ChalkDict]
    ## build only: a copy of the chalk-time host info collected before
    ## policies run, e.g. `SBOM`, `SAST` and `SECRET_SCANNER` when those
    ## tools are enabled. Nil for push, whose policies run before collection;
    ## push rules read `pushMarks` instead.
    host*: ChalkDict

  PolicyRule* = ref object
    name*: string
    ## Rules that need every image the command references. Subject collection
    ## errors are reported against them, as an incomplete list could let a
    ## disallowed image through.
    requiresAllSubjects*: bool
    ## the rule scans `contextDirs`, so a build context it cannot scan is an
    ## error rather than a silent pass
    requiresContext*: bool
    ## Collects context information when available, with a rule-specific
    ## fallback rather than automatically treating context errors as findings.
    usesContext*: bool
    ## Reads the rule's configuration for this evaluation and returns whether
    ## the rule is enabled. Raising reports a configuration error.
    load*:  proc(): bool
    check*: proc(subjects: seq[PolicySubject]): seq[PolicyFinding]
    ## used instead of `check` when set, see `newPolicyInputRule`
    checkInput*: proc(input: PolicyInput): seq[PolicyFinding]
    ## optional, describes the loaded configuration for the step summary
    hint*:  proc(): PolicyHint

var
  registeredRules: seq[PolicyRule]
  pendingNotices:  seq[PolicyNotice]

proc newPolicyRule*(name: string,
                    load: proc(): bool,
                    check: proc(subjects: seq[PolicySubject]): seq[PolicyFinding],
                    requiresAllSubjects = false,
                    hint: proc(): PolicyHint = nil) =
  for rule in registeredRules:
    if rule.name == name:
      raise newException(ValueError, "policy rule is already registered: " & name)
  registeredRules.add(PolicyRule(name: name, load: load, check: check,
                                 requiresAllSubjects: requiresAllSubjects,
                                 hint: hint))

proc newPolicyInputRule*(name: string,
                         load: proc(): bool,
                         check: proc(input: PolicyInput): seq[PolicyFinding],
                         requiresAllSubjects = false,
                         requiresContext = false,
                         hint: proc(): PolicyHint = nil,
                         usesContext = false) =
  ## A rule that sees the whole `PolicyInput`, not just its image subjects.
  newPolicyRule(name, load, nil, requiresAllSubjects, hint)
  registeredRules[^1].checkInput      = check
  registeredRules[^1].requiresContext = requiresContext
  registeredRules[^1].usesContext     = usesContext

iterator policyRules*(): PolicyRule =
  for rule in registeredRules:
    yield rule

proc hasPolicyRules*(): bool =
  len(registeredRules) > 0

proc addPolicyNotice*(rule, message: string) =
  ## Reports `message` for the policy being evaluated without affecting its
  ## result, see `PolicyNotice`
  pendingNotices.add(PolicyNotice(rule: rule, message: message))

proc takePolicyNotices*(): seq[PolicyNotice] =
  result = pendingNotices
  pendingNotices = @[]

proc collectionError*(reason: string, image = ""): PolicyFinding =
  ## the engine attributes it to each rule that requires all subjects
  PolicyFinding(kind: "error", image: image, reason: reason)

proc firstDigest*(self: PolicySubject): string =
  if len(self.digests) > 0:
    return self.digests[0]
  return ""

proc newFinding*(subject: PolicySubject, rule, kind, reason: string): PolicyFinding =
  return PolicyFinding(
    rule:   rule,
    kind:   kind,
    image:  subject.raw,
    digest: subject.firstDigest(),
    stage:  subject.stage,
    source: subject.source,
    reason: reason,
  )

proc newSubjectFinding*(rule, kind, subject, reason: string,
                        location = "", severity = ""): PolicyFinding =
  ## a finding about something other than an image
  PolicyFinding(
    rule:     rule,
    kind:     kind,
    subject:  subject,
    location: location,
    severity: severity,
    reason:   reason,
  )
