##
## Copyright (c) 2023-2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  strutils,
]

proc applySubstitutions*(s: string, lookup: proc(key: string): string): string =
  ## Replaces {KEY} placeholders in s by calling lookup(KEY.toUpperAscii()).
  ## Raises ValueError on malformed braces.
  var
    key   = ""
    inKey = false
  for c in s:
    if c == '{':
      if inKey:
        raise newException(
          ValueError,
          s & ": invalid format string. '{' is repeated without closing previous occurrence",
        )
      inKey = true
      key   = ""
      continue
    elif c == '}':
      if not inKey:
        raise newException(
          ValueError,
          s & ": invalid format string. '}' is occurring without matching '{'",
        )
      inKey = false
      if key == "":
        raise newException(
          ValueError,
          s & ": invalid format string. '{}' is an empty placeholder",
        )
      result &= lookup(key.toUpperAscii())
      continue
    if inKey:
      key.add(c)
    else:
      result.add(c)
  if inKey:
    raise newException(
      ValueError,
      s & ": invalid format string. '{' is not closed",
    )
