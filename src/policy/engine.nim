##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Build policy evaluation. Callers collect the images a docker
## command references and this module runs every registered policy
## rule (see policy/rules.nim) against them.

import ".."/[
  types,
]
import "."/[
  api,
  configuration,
  rules,
]

export api, configuration

type
  PolicyCollector* = proc(): PolicyInput {.closure.}

proc evaluatePolicies*(settings: PolicyConfig,
                       rules:    seq[PolicyRule],
                       input:    PolicyInput,
                       build:    ChalkDict,
                       findings: seq[PolicyFinding] = @[]) =
  ## Runs `rules`, records the outcome for reporting and raises
  ## `PolicyViolation` when an enforced policy blocks the command.
  let mode = settings.mode
  if mode notin ["audit", "enforce"]:
    return

  var
    findings   = findings
    attributed = false
  for rule in rules:
    if rule.requiresAllSubjects:
      attributed = true
      for e in input.errors:
        var f = e
        f.rule = rule.name
        findings.add(f)
    try:
      findings.add(rule.check(input.subjects))
    except CatchableError:
      findings.add(PolicyFinding(rule:   rule.name,
                                 kind:   "error",
                                 reason: "could not evaluate: " & getCurrentExceptionMsg()))

  if not attributed:
    for e in input.errors:
      trace("policy: no enabled rule needs all subjects, ignoring: " & $e)

  if len(findings) == 0:
    trace("policy: all policies passed")
    return

  var
    violations = 0
    failures   = 0
  for f in findings:
    if f.kind == "violation":
      inc(violations)
    else:
      inc(failures)

  let
    blockOnError = settings.onError == "block"
    blocked      = mode == "enforce" and (violations > 0 or (failures > 0 and blockOnError))
    outcome      =
      if blocked:
        "blocked"
      elif violations > 0:
        "violation"
      else:
        "error"

  policyOutcome = PolicyOutcome(
    id:       settings.id,
    mode:     mode,
    result:   outcome,
    findings: findings,
    build:    build,
  )

  # audit findings are warnings so they do not pollute _OP_ERRORS;
  # the policy report is the source of truth for audit mode
  for f in findings:
    if blocked or f.kind == "error":
      error("policy: " & $f)
    else:
      warn("policy (audit, not enforced): " & $f)

  if blocked:
    let command = unpack[string](build.getOrDefault("command", pack("docker")))
    raise newException(PolicyViolation,
                       command & " blocked by policy (" & $violations & " violation(s), " &
                       $failures & " error(s))")

proc evaluatePolicies*(build: ChalkDict, collect: PolicyCollector) =
  ## Rule loading and subject collection belong to evaluation: failures here
  ## must never reach docker's generic failsafe without honoring policy.on_error.
  policyEvaluated = true
  let settings = policyControls()
  if settings.mode notin ["audit", "enforce"]:
    return
  if settings.configError != "":
    # rules must not run on a configuration that could not be read
    evaluatePolicies(settings, @[], PolicyInput(), build,
                     @[PolicyFinding(rule: "config", kind: "error", reason: settings.configError)])
    return
  loadPolicyRules()
  var
    findings: seq[PolicyFinding]
    enabled:  seq[PolicyRule]
  for rule in policyRules():
    try:
      if rule.load():
        enabled.add(rule)
    except CatchableError:
      findings.add(PolicyFinding(rule:   rule.name,
                                 kind:   "error",
                                 reason: "could not load configuration: " & getCurrentExceptionMsg()))
  if len(enabled) == 0 and len(findings) == 0:
    return
  var input: PolicyInput
  if len(enabled) > 0:
    try:
      input = collect()
    except CatchableError:
      input.errors.add(collectionError("could not collect policy subjects: " &
                                       getCurrentExceptionMsg()))
  evaluatePolicies(settings, enabled, input, build, findings)
