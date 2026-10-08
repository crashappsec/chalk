##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Build policy outcome shared between policy evaluation,
## the `policy` plugin (which reports the `_POLICY_*` keys)
## and reporting (which publishes the `policy` topic).

import ".."/[
  types,
]

type
  PolicyFinding* = object
    policyId*: string # id of the policy that produced the finding
    rule*:     string
    kind*:     string # "violation" or "error"
    image*:    string
    digest*:   string
    stage*:    string
    source*:   string # "from", "copy_from" or "mount_from"
    reason*:   string

  PolicyResult* = object
    ## outcome of one evaluated policy
    id*:       string
    mode*:     string
    onError*:  string
    result*:   string # "pass", "violation", "blocked" or "error"
    findings*: seq[PolicyFinding]

  PolicyOutcome* = ref object
    mode*:      string # "enforce" when any evaluated policy enforces
    result*:    string # "violation", "blocked" or "error", across policies
    findings*:  seq[PolicyFinding] # of every policy
    policies*:  seq[PolicyResult]
    build*:     ChalkDict
    published*: bool

  PolicyViolation* = object of CatchableError
    ## Raised when an enforced policy blocks the docker command.
    ## It must never trigger the docker failsafe which would re-run
    ## docker without chalk.

var policyOutcome*: PolicyOutcome = nil
# set once policies run so a later failure is left to the docker failsafe
var policyEvaluated* = false

proc id*(self: PolicyOutcome): string =
  ## the policy id when a single policy was evaluated, as `_POLICY_ID`
  if self != nil and len(self.policies) == 1:
    return self.policies[0].id
  return ""

proc asDict(self: PolicyFinding): TableRef[string, string] =
  result = newTable[string, string]()
  result["policy_id"] = self.policyId
  result["rule"]      = self.rule
  result["kind"]      = self.kind
  result["image"]     = self.image
  result["digest"]    = self.digest
  result["stage"]     = self.stage
  result["source"]    = self.source
  result["reason"]    = self.reason

proc asDict(self: PolicyResult): TableRef[string, string] =
  result = newTable[string, string]()
  result["id"]       = self.id
  result["mode"]     = self.mode
  result["on_error"] = self.onError
  result["result"]   = self.result

proc asChalkDict*(self: PolicyOutcome): ChalkDict =
  result = ChalkDict()
  if self == nil:
    return
  var
    findings = newSeq[TableRef[string, string]]()
    policies = newSeq[TableRef[string, string]]()
  for f in self.findings:
    findings.add(f.asDict())
  for p in self.policies:
    policies.add(p.asDict())
  result["_POLICY_MODE"]     = pack(self.mode)
  if self.id != "":
    result["_POLICY_ID"]     = pack(self.id)
  result["_POLICY_RESULT"]   = pack(self.result)
  result["_POLICY_RESULTS"]  = pack(policies)
  result["_POLICY_FINDINGS"] = pack(findings)
  result["_POLICY_BUILD"]    = pack(self.build)

proc `$`*(self: PolicyFinding): string =
  if self.policyId != "":
    result = self.policyId & ": "
  result &= self.rule & ": "
  if self.image != "":
    result &= self.image
    if self.stage != "":
      result &= " (stage " & self.stage & ", " & self.source & ")"
    result &= " - "
  result &= self.reason
