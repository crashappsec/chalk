##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import std/strutils

# very simple semver implementation
# it this does NOT handle full semver spec
# it only handles basic dot-separated version format

type Version* = ref object
  major: int
  minor: int
  patch: int
  name:  string

proc parseVersion*(version: string): Version =
  var
    major = 0
    minor = 0
    patch = 0
  let
    name  = version.strip(chars={'v', ',', '.'})
    parts = name.split('.')
  case len(parts):
    of 1:
      major = parseInt(parts[0])
    of 2:
      major = parseInt(parts[0])
      minor = parseInt(parts[1])
    of 3:
      major = parseInt(parts[0])
      minor = parseInt(parts[1])
      patch = parseInt(parts[2])
    else:
      raise newException(ValueError, "Invalid or unsupported version format")
  new result
  result.name = name
  result.major = major
  result.minor = minor
  result.patch = patch

# version parts tuple used for comparison
proc parts(self: Version): (int, int, int) =
  return (self.major, self.minor, self.patch)

proc `==`*(self: Version, other: Version): bool =
  return self.parts() == other.parts()

proc `!=`*(self: Version, other: Version): bool =
  return self.parts() != other.parts()

proc `>`*(self: Version, other: Version): bool =
  return self.parts() > other.parts()

proc `>=`*(self: Version, other: Version): bool =
  return self.parts() >= other.parts()

proc `<`*(self: Version, other: Version): bool =
  return self.parts() < other.parts()

proc `<=`*(self: Version, other: Version): bool =
  return self.parts() <= other.parts()

proc `$`*(self: Version): string =
  return self.name

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
