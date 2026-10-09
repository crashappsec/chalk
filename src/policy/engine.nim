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
  repo,
  rules,
  summary,
]

export api, configuration, repo, summary

type
  PolicyCollector* = proc(): PolicyInput {.closure.}
  ## normalized repository the command builds, empty when unknown
  PolicyRepoResolver* = proc(): string {.closure.}

proc evaluatePolicy*(settings: PolicyConfig,
                     rules:    seq[PolicyRule],
                     input:    PolicyInput,
                     findings: seq[PolicyFinding] = @[]): PolicyResult =
  ## Runs `rules` for one policy. Policies are independent: each decides
  ## with its own mode and on_error whether its findings block the command.
  let mode = settings.activeMode()
  result = PolicyResult(
    id:            settings.id,
    mode:          settings.mode,
    onError:       settings.onError,
    effectiveMode: mode,
    modeSource:    (if settings.modeSource != "": settings.modeSource else: "default"),
    repo:          settings.repo,
    hasEnforceRepos: len(settings.enforceRepos) > 0,
  )
  var
    findings   = findings
    attributed = false
  for rule in rules:
    if rule.hint != nil:
      try:
        result.hints.add(rule.hint())
      except CatchableError:
        trace("policy: no step summary hint for " & rule.name & ": " & getCurrentExceptionMsg())
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

  var
    violations = 0
    failures   = 0
  for f in findings.mitems():
    f.policyId = settings.id
    if f.kind == "violation":
      inc(violations)
    else:
      inc(failures)
  result.findings = findings

  let blockOnError = settings.onError == "block"
  result.result =
    if len(findings) == 0:
      "pass"
    elif mode == "enforce" and (violations > 0 or (failures > 0 and blockOnError)):
      "blocked"
    elif violations > 0:
      "violation"
    else:
      "error"

proc recordPolicyResults*(results: seq[PolicyResult], build: ChalkDict) =
  ## Records the outcome of all evaluated policies for reporting and raises
  ## `PolicyViolation` when any of them blocks the command.
  var
    findings:   seq[PolicyFinding]
    blockedIds: seq[string]
    violations = 0
    failures   = 0
    mode       = "audit"
    anyViolation = false
  # queued before raising so a blocked command still gets its summary
  recordPolicySummary(results, build)
  for r in results:
    findings.add(r.findings)
    if r.effectiveMode == "enforce":
      mode = "enforce"
    if r.result == "violation":
      anyViolation = true
    if r.result != "blocked":
      continue
    blockedIds.add(r.id)
    for f in r.findings:
      if f.kind == "violation":
        inc(violations)
      else:
        inc(failures)

  if len(findings) == 0:
    trace("policy: all policies passed")
    return

  let blocked = len(blockedIds) > 0
  policyOutcome = PolicyOutcome(
    mode:     mode,
    result:   (if blocked: "blocked" elif anyViolation: "violation" else: "error"),
    findings: findings,
    policies: results,
    build:    build,
  )

  # audit findings are warnings so they do not pollute _OP_ERRORS;
  # the policy report is the source of truth for audit mode
  for r in results:
    for f in r.findings:
      if r.result == "blocked" or f.kind == "error":
        error("policy: " & $f)
      else:
        warn("policy (audit, not enforced): " & $f)

  if blocked:
    let command = unpack[string](build.getOrDefault("command", pack("docker")))
    var message = command & " blocked by policy"
    for id in blockedIds:
      if id != "":
        message &= " " & id
    raise newException(PolicyViolation,
                       message & " (" & $violations & " violation(s), " &
                       $failures & " error(s))")

proc evaluatePolicies*(settings: PolicyConfig,
                       rules:    seq[PolicyRule],
                       input:    PolicyInput,
                       build:    ChalkDict,
                       findings: seq[PolicyFinding] = @[]) =
  ## Single-policy shorthand for `evaluatePolicy` + `recordPolicyResults`.
  if not settings.isEvaluated():
    return
  recordPolicyResults(@[evaluatePolicy(settings, rules, input, findings)], build)

proc configError(settings: PolicyConfig): PolicyFinding =
  PolicyFinding(rule: "config", kind: "error", reason: settings.configError)

proc resolveModes(configs: seq[PolicyConfig], resolver: PolicyRepoResolver): seq[PolicyConfig] =
  ## the repository is only looked up when a policy has `enforce_repos`
  var
    repo     = ""
    resolved = false
  for p in configs:
    if p.configError != "" or len(p.enforceRepos) == 0:
      result.add(p)
      continue
    if not resolved:
      resolved = true
      if resolver != nil:
        try:
          repo = resolver()
        except CatchableError:
          warn("policy: could not determine repository: " & getCurrentExceptionMsg())
      trace("policy: repository for enforce_repos: " & (if repo != "": repo else: "unknown"))
    result.add(p.resolveMode(repo))

proc evaluatePolicies*(build:   ChalkDict,
                       collect: PolicyCollector,
                       rules:   seq[PolicyRule],
                       repo:    PolicyRepoResolver = nil) =
  ## Evaluates every configured policy with `rules`.
  ## Rule loading and subject collection belong to evaluation: failures here
  ## must never reach docker's generic failsafe without honoring policy.on_error.
  policyEvaluated = true
  var policies: seq[PolicyConfig]
  for p in policyConfigs().resolveModes(repo):
    if p.isEvaluated():
      policies.add(p)
  if len(policies) == 0:
    return
  var
    results:   seq[PolicyResult]
    input:     PolicyInput
    collected = false
  for settings in policies:
    if settings.configError != "":
      # rules must not run on a configuration that could not be read
      results.add(evaluatePolicy(settings, @[], PolicyInput(), @[settings.configError()]))
      continue
    # rules keep the settings they load until the next load, so each policy
    # is loaded and checked before the next one is selected
    selectPolicy(settings)
    var
      findings: seq[PolicyFinding]
      enabled:  seq[PolicyRule]
    for rule in rules:
      try:
        if rule.load():
          enabled.add(rule)
      except CatchableError:
        findings.add(PolicyFinding(rule:   rule.name,
                                   kind:   "error",
                                   reason: "could not load configuration: " & getCurrentExceptionMsg()))
    # subjects are collected once, and only if some policy needs them, as
    # collecting them may query registries
    if len(enabled) > 0 and not collected:
      collected = true
      try:
        input = collect()
      except CatchableError:
        input.errors.add(collectionError("could not collect policy subjects: " &
                                         getCurrentExceptionMsg()))
    results.add(evaluatePolicy(settings, enabled, input, findings))
  selectPolicy(PolicyConfig())
  recordPolicyResults(results, build)

proc evaluatePolicies*(build:   ChalkDict,
                       collect: PolicyCollector,
                       repo:    PolicyRepoResolver = nil) =
  ## Evaluates every configured policy with the registered rules.
  if not policyEnabled():
    policyEvaluated = true
    return
  loadPolicyRules()
  var rules: seq[PolicyRule]
  for rule in policyRules():
    rules.add(rule)
  evaluatePolicies(build, collect, rules, repo)
