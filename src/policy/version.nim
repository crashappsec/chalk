##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Package version ordering for policy version ranges, following semver 2.0
## precedence (https://semver.org/#spec-item-11) generalized to any number of
## numeric release components. utils/semver is kept for chalk's own tool
## version checks, which rely on its looser parsing.

import std/[
  json,
  strutils,
]

type
  PackageVersion* = object
    release:    seq[int]
    prerelease: seq[string]

const supported = "comparisons support dot-separated numbers with an optional " &
                  "-prerelease and +build metadata"

proc parsePackageVersion*(value: string): PackageVersion =
  ## Raises `ValueError` for versions whose order is ecosystem specific, such
  ## as Debian epochs (`1:2.36-9`), Python post-releases (`1.0.post1`) or
  ## Maven qualifiers (`1.2.3.RELEASE`).
  var s = value.strip()
  # go module versions carry a `v` prefix other ecosystems do not
  if len(s) > 1 and s[0] in {'v', 'V'} and s[1] in Digits:
    s = s[1 .. ^1]
  let plus = s.find('+')
  if plus >= 0:
    s = s[0 ..< plus]
  let dash = s.find('-')
  let release = if dash >= 0: s[0 ..< dash] else: s
  if dash >= 0:
    for identifier in s[dash + 1 .. ^1].split('.'):
      if identifier == "" or not identifier.allCharsInSet(Letters + Digits + {'-'}):
        raise newException(ValueError, "unsupported version " & escapeJson(value) &
                                       " (" & supported & ")")
      result.prerelease.add(identifier)
  for part in release.split('.'):
    if part == "" or not part.allCharsInSet(Digits):
      raise newException(ValueError, "unsupported version " & escapeJson(value) &
                                     " (" & supported & ")")
    try:
      result.release.add(parseInt(part))
    except ValueError:
      raise newException(ValueError, "unsupported version " & escapeJson(value) &
                                     " (number too large)")

proc cmpIdentifier(a, b: string): int =
  let
    aNumeric = a.allCharsInSet(Digits)
    bNumeric = b.allCharsInSet(Digits)
  if aNumeric and bNumeric:
    # compare by length first so long numbers do not overflow
    let
      x = a.strip(trailing = false, chars = {'0'})
      y = b.strip(trailing = false, chars = {'0'})
    if len(x) != len(y):
      return cmp(len(x), len(y))
    return cmp(x, y)
  if aNumeric:
    return -1
  if bNumeric:
    return 1
  cmp(a, b)

proc cmp*(a, b: PackageVersion): int =
  ## missing release components are 0, so `1.2` equals `1.2.0`
  for i in 0 ..< max(len(a.release), len(b.release)):
    let
      x = if i < len(a.release): a.release[i] else: 0
      y = if i < len(b.release): b.release[i] else: 0
    if x != y:
      return cmp(x, y)
  if len(a.prerelease) == 0 or len(b.prerelease) == 0:
    return cmp(len(b.prerelease), len(a.prerelease))
  for i in 0 ..< min(len(a.prerelease), len(b.prerelease)):
    let c = cmpIdentifier(a.prerelease[i], b.prerelease[i])
    if c != 0:
      return c
  cmp(len(a.prerelease), len(b.prerelease))

proc `==`*(a, b: PackageVersion): bool = cmp(a, b) == 0
proc `<`*(a, b: PackageVersion): bool  = cmp(a, b) < 0
proc `<=`*(a, b: PackageVersion): bool = cmp(a, b) <= 0
