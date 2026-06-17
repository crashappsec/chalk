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
