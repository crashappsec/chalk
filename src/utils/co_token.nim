##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Validation of Crash Override tokens: either an unexpired JWT or an opaque
## WorkOS API key.

import std/[
  strutils,
]
import pkg/[
  nimutils/jwt,
]

const
  apiKeyPrefix    = "sk_"
  apiKeyMinLength = 20

proc isApiKey*(token: string): bool =
  ## Shape check only; the key is validated server-side.
  if not token.startsWith(apiKeyPrefix) or len(token) < apiKeyMinLength:
    return false
  for c in token:
    if c in Whitespace:
      return false
  return true

proc isJwtAlive*(token: string): bool =
  try:
    # TODO validate full JWT structure
    return parseJwtToken(token).isStillAlive()
  except:
    return false

proc isCoTokenValid*(token: string): bool =
  if len(token) == 0:
    return false
  return token.isApiKey() or token.isJwtAlive()
