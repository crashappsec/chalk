##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Reports the outcome of build policy evaluation.

import ".."/[
  plugin_api,
  policy/state,
  types,
]

proc policyGetRunTimeHostInfo*(self: Plugin,
                               objs: seq[ChalkObj]):
                              ChalkDict {.cdecl.} =
  return policyOutcome.asChalkDict()

proc loadPolicy*() =
  newPlugin("policy",
            rtHostCallback = RunTimeHostCb(policyGetRunTimeHostInfo))
