##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  base64,
]
import "."/[
  strings,
]

export base64

proc safeDecode*(data: string): string =
  try:
    return decode(data.removeChars(Whitespace))
  except:
    return ""
