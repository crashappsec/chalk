##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Build policy evaluation. Callers collect the images a docker
## command references and this module checks them against the
## `policy` configuration section.

import ".."/[
  config,
  types,
]
import "."/[
  golden_images,
  state,
]

export state

type
  PolicySubject* = object
    image*:   DockerImage # as referenced, used for matching
    raw*:     string      # as referenced, used for reporting
    digests*: seq[string] # all known digests of the image
    stage*:   string
    source*:  string      # "from" or "copy_from"

# sections declared without some fields (or not declared at all when set via
# dotted assignment) do not get spec defaults, hence explicit defaults here

proc policyMode*(): string =
  return attrGetOpt[string]("policy.mode").get("off")

proc goldenImagesEnabled*(): bool =
  return attrGetOpt[bool]("policy.golden_images.enabled").get(false)

proc policyEnabled*(): bool =
  return policyMode() in ["audit", "enforce"]

proc getAllowedImages(): seq[AllowedImage] =
  # con4m boxes tuples as lists
  let entries = attrGetOpt[seq[Box]]("policy.golden_images.allowed").get(@[])
  for entry in entries:
    let parts = unpack[seq[Box]](entry)
    if len(parts) != 2:
      raise newException(ValueError, "policy.golden_images.allowed entries must be (kind, value) tuples")
    result.add((unpack[string](parts[0]), unpack[string](parts[1])))

proc firstDigest(self: PolicySubject): string =
  if len(self.digests) > 0:
    return self.digests[0]
  return ""

proc newFinding(subject: PolicySubject, rule, kind, reason: string): PolicyFinding =
  return PolicyFinding(
    rule:   rule,
    kind:   kind,
    image:  subject.raw,
    digest: subject.firstDigest(),
    stage:  subject.stage,
    source: subject.source,
    reason: reason,
  )

proc checkGoldenImages(subjects: seq[PolicySubject]): seq[PolicyFinding] =
  if not goldenImagesEnabled():
    return
  let
    allowed      = getAllowedImages()
    checkCopy    = attrGetOpt[bool]("policy.golden_images.check_copy_from").get(true)
    message      = attrGetOpt[string]("policy.golden_images.message").get("")
  for subject in subjects:
    if subject.source == "copy_from" and not checkCopy:
      continue
    let (res, reason) = subject.image.checkImage(subject.digests, allowed)
    case res
    of mrAllowed:
      continue
    of mrDenied:
      var fullReason = reason
      if message != "":
        fullReason &= ". " & message
      result.add(subject.newFinding("golden_images", "violation", fullReason))
    of mrUnknown:
      result.add(subject.newFinding("golden_images", "error", reason))

proc runCustomCheck(subjects: seq[PolicySubject]): seq[PolicyFinding] =
  let cb = attrGetOpt[CallbackObj]("policy.custom_check")
  if cb.isNone():
    return
  for subject in subjects:
    try:
      let
        args = @[
          pack(subject.raw),
          pack(subject.firstDigest()),
          pack(subject.stage),
          pack(subject.source),
        ]
        reason = unpack[string](runCallback(cb.get(), args).get())
      if reason != "":
        result.add(subject.newFinding("custom_check", "violation", reason))
    except:
      result.add(subject.newFinding("custom_check", "error",
                                    "custom_check failed: " & getCurrentExceptionMsg()))

proc evaluatePolicies*(subjects: seq[PolicySubject],
                       build:    ChalkDict,
                       errors:   seq[PolicyFinding] = @[]) =
  ## Evaluates all enabled policies, records the outcome for reporting
  ## and raises `PolicyViolation` when an enforced policy blocks the build.
  let mode = policyMode()
  if mode notin ["audit", "enforce"]:
    return

  var findings = errors
  try:
    findings.add(checkGoldenImages(subjects))
  except:
    findings.add(PolicyFinding(rule:   "golden_images",
                               kind:   "error",
                               reason: "could not evaluate: " & getCurrentExceptionMsg()))
  findings.add(runCustomCheck(subjects))

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
    blockOnError = attrGetOpt[string]("policy.on_error").get("allow") == "block"
    blocked      = mode == "enforce" and (violations > 0 or (failures > 0 and blockOnError))
    outcome      =
      if blocked:
        "blocked"
      elif violations > 0:
        "violation"
      else:
        "error"

  policyOutcome = PolicyOutcome(
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
