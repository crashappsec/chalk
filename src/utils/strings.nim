##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  strutils,
]

export strutils

proc replaceItemWith*(data: seq[string], match: string, sub: string): seq[string] =
  result = @[]
  for i in data:
    if i == match:
      result.add(sub)
    else:
      result.add(i)

proc isInt*(i: string): bool =
  try:
    discard parseInt(i)
    return true
  except:
    return false

proc isUInt*(i: string): bool =
  try:
    discard parseUInt(i)
    return true
  except:
    return false

proc splitBy*(s: string, sep: string, default: string = ""): (string, string) =
  let parts = s.split(sep, maxsplit = 1)
  if len(parts) == 2:
    return (parts[0], parts[1])
  return (s, default)

proc rSplitBy*(s: string, sep: string, default: string = ""): (string, string) =
  let parts = s.rsplit(sep, maxsplit = 1)
  if len(parts) == 2:
    return (parts[0], parts[1])
  return (s, default)

proc removeSuffix*(s: string, suffix: string | char): string =
  # similar to strutil except it returns result back
  # vs in-place removal in stdlib
  result = s
  result.removeSuffix(suffix)

proc removePrefix*(s: string, prefix: string): string =
  # similar to strutil except it returns result back
  # vs in-place removal in stdlib
  result = s
  result.removePrefix(prefix)

proc strip*(items: seq[string],
            leading  = true,
            trailing = true,
            chars    = Whitespace,
            ): seq[string] =
  result = @[]
  for i in items:
    result.add(i.strip(leading = leading, trailing = trailing, chars = chars))

proc splitLinesAnd*(items: string, keepEol = false, keepEmpty = true): seq[string] =
  let lines = items.splitLines(keepEol = keepEol)
  if keepEmpty:
    return lines
  for i in lines:
    if i != "":
      result.add(i)

proc elseWhenEmpty*(s: string, default: string): string =
  if s == "":
    return default
  return s

proc startsWithAnyOf*(s: string, suffixes: openArray[string]): bool =
  for i in suffixes:
    if s.startsWith(i):
      return true
  return false

proc coalesce*(data: varargs[string]): string =
  for s in data:
    if s != "":
      return s
  return ""
