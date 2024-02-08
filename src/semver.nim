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
  major:  int
  minor:  int
  patch:  int
  suffix: string
  name:   string

proc parseVersion*(version: string): Version =
  var
    major  = 0
    minor  = 0
    patch  = 0
    suffix = ""
  let
    name     = version.strip(chars={'V', 'v'}, trailing=false).strip(chars={',', '.', '-', '+'})
    sections = name.split({'-', '+'}, maxsplit=1)
    parts    = sections[0].split('.')
  case len(parts):
    of 1:
      major  = parseInt(parts[0])
    of 2:
      major  = parseInt(parts[0])
      minor  = parseInt(parts[1])
    of 3:
      major  = parseInt(parts[0])
      minor  = parseInt(parts[1])
      patch  = parseInt(parts[2])
    else:
      raise newException(ValueError, "Invalid or unsupported version format")
  if len(sections) == 2:
    suffix = sections[1]
  return Version(name:   name,
                 major:  major,
                 minor:  minor,
                 patch:  patch,
                 suffix: suffix)

# version parts tuple used for comparison
proc parts(self: Version): (int, int, int, string) =
  # TODO how to compare suffix?
  # for now treating any suffix as less than no suffix
  # assumping any suffix is for pre-releases which is not ideal
  # correct but it is fine for chalk versions
  # this handles things like 1-dev < 1.0
  # no suffix is normalized to highest ascii char code \u7f
  # hence it is always greater then any legitimate ascii string
  let suffix = if self.suffix == "": "\u7f" else: self.suffix
  return (self.major, self.minor, self.patch, suffix)

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
  assert($(parseVersion("0.1-dev")) == "0.1-dev")
  assert($(parseVersion("0.1.0")) == "0.1.0")
  assert($(parseVersion("0.1.0-dev")) == "0.1.0-dev")

  assert(parseVersion("0.1") == parseVersion("0.1.0"))
  assert(parseVersion("0.1.0") == parseVersion("0.1.0"))
  assert(not(parseVersion("0.1") == parseVersion("0.1.5")))
  assert(not(parseVersion("0.1") == parseVersion("0.1-dev")))
  assert(not(parseVersion("0.1.0") == parseVersion("0.1.5")))

  assert(parseVersion("0.1") != parseVersion("0.1.5"))
  assert(parseVersion("0.1") != parseVersion("0.1-dev"))
  assert(parseVersion("0.1.0") != parseVersion("0.1.5"))
  assert(not(parseVersion("0.1") != parseVersion("0.1")))
  assert(not(parseVersion("0.1.0") != parseVersion("0.1")))

  assert(parseVersion("0.1-dev") < parseVersion("0.1"))
  assert(parseVersion("0.1") < parseVersion("0.1.5"))
  assert(parseVersion("0.1.0") < parseVersion("0.1.5"))
  assert(not(parseVersion("0.1") < parseVersion("0.1")))
  assert(not(parseVersion("0.1") < parseVersion("0.1.0")))

  assert(parseVersion("0.1-dev") <= parseVersion("0.1"))
  assert(parseVersion("0.1") <= parseVersion("0.1.5"))
  assert(parseVersion("0.1.0") <= parseVersion("0.1.5"))
  assert(parseVersion("0.1") <= parseVersion("0.1"))
  assert(parseVersion("0.1") <= parseVersion("0.1.0"))

  assert(parseVersion("0.1") > parseVersion("0.1-dev"))
  assert(parseVersion("0.1.5") > parseVersion("0.1"))
  assert(parseVersion("0.1.5") > parseVersion("0.1.0"))
  assert(not(parseVersion("0.1") > parseVersion("0.1")))
  assert(not(parseVersion("0.1.0") > parseVersion("0.1")))

  assert(parseVersion("0.1") >= parseVersion("0.1-dev"))
  assert(parseVersion("0.1.5") >= parseVersion("0.1"))
  assert(parseVersion("0.1.5") >= parseVersion("0.1.0"))
  assert(parseVersion("0.1") >= parseVersion("0.1"))
  assert(parseVersion("0.1.0") >= parseVersion("0.1"))
