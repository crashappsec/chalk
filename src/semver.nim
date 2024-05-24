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
  # no suffix is normalized to highest ascii char code \x7f
  # hence it is always greater then any legitimate ascii string
  let suffix = if self.suffix == "": "\x7f" else: self.suffix
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

proc normalize*(self: Version): string =
  let s = $self
  if s == "0":
    return ""
  return s

proc getVersionFromLine*(line: string): Version =
  for word in line.splitWhitespace():
    if '.' in word:
      try:
        return parseVersion(word)
      except:
        # word wasnt a version number
        discard
  raise newException(ValueError, "no version found")

proc getVersionFromLineWhich*(lines: seq[string],
                              startsWith = "",
                              contains = "",
                              isAfterLineStartingWith = ""): Version =
  var isAfter = false
  for line in lines:
    isAfter = isAfter or line.startsWith(isAfterLineStartingWith)
    if not isAfter:
      continue
    if startsWith != "" and not line.startsWith(startsWith):
      continue
    if contains != "" and contains notin line:
      continue
    try:
      return getVersionFromLine(line)
    except:
      discard
  raise newException(ValueError, "no version found")
