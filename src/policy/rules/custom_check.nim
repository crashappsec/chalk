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
import ".."/api

var callback: CallbackObj

proc loadCustomCheck(): bool =
  let cb = attrGetOpt[CallbackObj]("policy.custom_check")
  if cb.isNone():
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
