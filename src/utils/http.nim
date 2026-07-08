##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  httpclient,
  httpcore,
  strutils,
]
import ".."/[
  config,
  run_management,
  types,
]

export httpclient
export httpcore

proc update*(self: HttpHeaders, with: HttpHeaders): HttpHeaders =
  for k, v in with.pairs():
    self[k] = v
  return self

proc mustGet*(headers: HttpHeaders, header: string, msg: string): string =
  if not headers.hasKey(header):
    raise newException(ValueError, msg)
  return headers[header]

proc mustGetInt*(headers: HttpHeaders, header: string, msg: string): int =
  let value = headers.mustGet(header, msg)
  try:
    return parseInt(value)
  except:
    raise newException(ValueError, msg & ": invalid integer: " & value)

proc withChalkCoreHeaders*(headers: HttpHeaders): HttpHeaders =
  ## Merges chalk core headers into `headers`, applying them last so they
  ## take precedence over any same-named user-configured header.
  ## _ACTION_ID is guarded: absent when no report template subscribes it.
  headers["X-Chalk-Version"] = getChalkExeVersion()
  let actionId = lookupCollectedKey("_ACTION_ID")
  if actionId.isSome():
    headers["X-Chalk-Action-Id"] = unpack[string](actionId.get())
  return headers

proc applyForwardedHeaders*(headers: HttpHeaders, response: Response): HttpHeaders =
  ## Copies headers listed in the response's x-forward-headers into headers.
  ## Allows the sign server to request that specific response headers be
  ## forwarded to the actual upload request (e.g. extra metadata headers).
  if not response.headers.hasKey("x-forward-headers"):
    return headers
  for item in response.headers["x-forward-headers"].strip().split(','):
    let name = item.strip()
    if response.headers.hasKey(name):
      headers[name] = response.headers[name]
  return headers
