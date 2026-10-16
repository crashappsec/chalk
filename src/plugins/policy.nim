##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Reports the outcome of build policy evaluation.

import ".."/[
  plugin_api,
  policy/github,
  policy/state,
  types,
]

proc policyGetChalkTimeArtifactInfo*(self: Plugin,
                                     obj:  ChalkObj):
                                    ChalkDict {.cdecl.} =
  ## build policies run before chalk-time artifact collection, so marks
  ## record the dependency review they did, see `dependencyReviewMark`
  result = ChalkDict()
  if dependencyReviewMark != nil:
    result[markKey] = pack(dependencyReviewMark)

proc policyGetRunTimeHostInfo*(self: Plugin,
                               objs: seq[ChalkObj]):
                              ChalkDict {.cdecl.} =
  return policyOutcome.asChalkDict()

proc loadPolicy*() =
  newPlugin("policy",
            ctArtCallback  = ChalkTimeArtifactCb(policyGetChalkTimeArtifactInfo),
            rtHostCallback = RunTimeHostCb(policyGetRunTimeHostInfo))
