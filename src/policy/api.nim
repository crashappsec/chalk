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
    source*:  string      # "from" or "copy_from"

  PolicyInput* = object
    subjects*: seq[PolicySubject]
    errors*:   seq[PolicyFinding] # subjects that could not be determined

  PolicyRule* = ref object
    name*: string
    ## Rules that need every image the command references. Subject collection
    ## errors are reported against them, as an incomplete list could let a
    ## disallowed image through.
    requiresAllSubjects*: bool
    ## Reads the rule's configuration for this evaluation and returns whether
    ## the rule is enabled. Raising reports a configuration error.
    load*:  proc(): bool
    check*: proc(subjects: seq[PolicySubject]): seq[PolicyFinding]

var registeredRules: seq[PolicyRule]

proc newPolicyRule*(name: string,
                    load: proc(): bool,
                    check: proc(subjects: seq[PolicySubject]): seq[PolicyFinding],
                    requiresAllSubjects = false) =
  for rule in registeredRules:
    if rule.name == name:
      raise newException(ValueError, "policy rule is already registered: " & name)
  registeredRules.add(PolicyRule(name: name, load: load, check: check,
                                 requiresAllSubjects: requiresAllSubjects))

iterator policyRules*(): PolicyRule =
  for rule in registeredRules:
    yield rule

proc hasPolicyRules*(): bool =
  len(registeredRules) > 0

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
