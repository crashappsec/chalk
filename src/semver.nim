##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import strutils, util

# very simple semver implementation
# it this does NOT handle full semver spec
# it only handles basic dot-separated version format

type Version* = ref object
    parts: seq[int]

proc parseVersion*(version: string): Version =
  new result
  result.parts = @[]
  for i in version.strip(chars={'v', ',', '.'}).split('.'):
    result.parts.add(parseInt(i))

proc `==`*(self: Version, other: Version): bool =
  for (a, b) in zipLongest(self.parts, other.parts, 0):
    if a != b:
      return false
  return true

proc `!=`*(self: Version, other: Version): bool =
  return not (self == other)

proc `>`*(self: Version, other: Version): bool =
  for (a, b) in zipLongest(self.parts, other.parts, 0):
    # allow == here as some digits could be be ==
    # as long as eventually there is one which is >
    if a < b:
      return false
    elif a > b:
      return true
  return false

proc `>=`*(self: Version, other: Version): bool =
  return self == other or self > other

proc `<`*(self: Version, other: Version): bool =
  return not (self >= other)

proc `<=`*(self: Version, other: Version): bool =
  return self == other or self < other

proc `$`*(self: Version): string =
  return self.parts.join(".")

when isMainModule:
  assert($(parseVersion("0.1")) == "0.1")
  assert($(parseVersion("0.1.0")) == "0.1.0")

  assert(parseVersion("0.1") == parseVersion("0.1.0"))
  assert(parseVersion("0.1.0") == parseVersion("0.1.0"))
  assert(not(parseVersion("0.1") == parseVersion("0.1.5")))
  assert(not(parseVersion("0.1.0") == parseVersion("0.1.5")))

  assert(parseVersion("0.1") != parseVersion("0.1.5"))
  assert(parseVersion("0.1.0") != parseVersion("0.1.5"))
  assert(not(parseVersion("0.1") != parseVersion("0.1")))
  assert(not(parseVersion("0.1.0") != parseVersion("0.1")))

  assert(parseVersion("0.1") < parseVersion("0.1.5"))
  assert(parseVersion("0.1.0") < parseVersion("0.1.5"))
  assert(not(parseVersion("0.1") < parseVersion("0.1")))
  assert(not(parseVersion("0.1") < parseVersion("0.1.0")))

  assert(parseVersion("0.1") <= parseVersion("0.1.5"))
  assert(parseVersion("0.1.0") <= parseVersion("0.1.5"))
  assert(parseVersion("0.1") <= parseVersion("0.1"))
  assert(parseVersion("0.1") <= parseVersion("0.1.0"))

  assert(parseVersion("0.1.5") > parseVersion("0.1"))
  assert(parseVersion("0.1.5") > parseVersion("0.1.0"))
  assert(not(parseVersion("0.1") > parseVersion("0.1")))
  assert(not(parseVersion("0.1.0") > parseVersion("0.1")))

  assert(parseVersion("0.1.5") >= parseVersion("0.1"))
  assert(parseVersion("0.1.5") >= parseVersion("0.1.0"))
  assert(parseVersion("0.1") >= parseVersion("0.1"))
  assert(parseVersion("0.1.0") >= parseVersion("0.1"))
