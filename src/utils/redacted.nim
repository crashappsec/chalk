##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

type Redacted* = ref object
  raw:      string
  redacted: string

proc redact*(raw: string): Redacted =
  return Redacted(raw: raw, redacted: raw)

proc redact*(raw: string, redacted: string): Redacted =
  return Redacted(raw: raw, redacted: redacted)

proc redact*(data: seq[string]): seq[Redacted] =
  result = @[]
  for i in data:
    result.add(redact(i))

proc redacted*(data: seq[Redacted]): seq[string] =
  result = @[]
  for i in data:
    result.add(i.redacted)

proc raw*(data: seq[Redacted]): seq[string] =
  result = @[]
  for i in data:
    result.add(i.raw)
