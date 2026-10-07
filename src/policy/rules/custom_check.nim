##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.custom_check`: a con4m callback that can reject any subject.

import "../.."/[
  config,
  types,
]
import ".."/[
  api,
  configuration,
]

var
  callback: CallbackObj
  warnedIgnored = false

proc loadCustomCheck(): bool =
  let cb = attrGetOpt[CallbackObj]("policy.custom_check")
  if cb.isNone():
    return false
  # a con4m callback belongs to no particular entry of a policies list, and
  # running it under each of them would report its findings once per policy
  if policyJsonIsList():
    if not warnedIgnored:
      warnedIgnored = true
      warn("policy: policy.custom_check is ignored when policy.config_json lists policies")
    return false
  callback = cb.get()
  return true

proc checkCustom(subjects: seq[PolicySubject]): seq[PolicyFinding] =
  for subject in subjects:
    try:
      let
        args = @[
          pack(subject.raw),
          pack(subject.firstDigest()),
          pack(subject.stage),
          pack(subject.source),
        ]
        reason = unpack[string](runCallback(callback, args).get())
      if reason != "":
        result.add(subject.newFinding("custom_check", "violation", reason))
    except CatchableError:
      result.add(subject.newFinding("custom_check", "error",
                                    "custom_check failed: " & getCurrentExceptionMsg()))

proc loadCustomCheckRule*() =
  # sees only the subjects that could be determined, as before rules existed
  newPolicyRule("custom_check", loadCustomCheck, checkCustom)
