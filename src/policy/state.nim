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
    rule*:   string
    kind*:   string # "violation" or "error"
    image*:  string
    digest*: string
    stage*:  string
    source*: string # "from" or "copy_from"
    reason*: string

  PolicyOutcome* = ref object
    id*:        string
    mode*:      string
    result*:    string # "violation", "blocked" or "error"
    findings*:  seq[PolicyFinding]
    build*:     ChalkDict
    published*: bool

  PolicyViolation* = object of CatchableError
    ## Raised when an enforced policy blocks the docker command.
    ## It must never trigger the docker failsafe which would re-run
    ## docker without chalk.

var policyOutcome*: PolicyOutcome = nil
# set once policies run so a later failure is left to the docker failsafe
var policyEvaluated* = false

proc asDict(self: PolicyFinding): TableRef[string, string] =
  result = newTable[string, string]()
  result["rule"]   = self.rule
  result["kind"]   = self.kind
  result["image"]  = self.image
  result["digest"] = self.digest
  result["stage"]  = self.stage
  result["source"] = self.source
  result["reason"] = self.reason

proc asChalkDict*(self: PolicyOutcome): ChalkDict =
  result = ChalkDict()
  if self == nil:
    return
  var findings = newSeq[TableRef[string, string]]()
  for f in self.findings:
    findings.add(f.asDict())
  result["_POLICY_MODE"]     = pack(self.mode)
  if self.id != "":
    result["_POLICY_ID"]     = pack(self.id)
  result["_POLICY_RESULT"]   = pack(self.result)
  result["_POLICY_FINDINGS"] = pack(findings)
  result["_POLICY_BUILD"]    = pack(self.build)

proc `$`*(self: PolicyFinding): string =
  result = self.rule & ": "
  if self.image != "":
    result &= self.image
    if self.stage != "":
      result &= " (stage " & self.stage & ", " & self.source & ")"
    result &= " - "
  result &= self.reason
