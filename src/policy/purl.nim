##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Package URL (purl) parsing and matching for policy rules that select
## packages by purl, e.g. `pkg:npm/lodash@<4.17.21` or `pkg:pypi/*colourama*`.
## https://github.com/package-url/purl-spec/blob/main/PURL-SPECIFICATION.rst
##
## Patterns are purls whose `type/namespace/name` is a glob (`*` matches any
## run of characters, including `/`; `?` one character) and whose version is
## either a glob or comma-separated comparisons (`<`, `<=`, `>`, `>=`, `=`,
## `==`, `!=`). Matching ignores case, qualifiers and subpaths, decodes
## percent-encoding (`%40angular` is `@angular`), normalizes pypi names and
## ignores the `v` prefix of go module versions.

import std/[
  json,
  strutils,
  uri,
]
import ".."/[
  utils/semver,
]
from ./rules/golden_images import globMatch

type
  PurlMatch* = enum
    pmMatch, pmNoMatch,
    ## the version cannot be compared with the pattern's range
    pmUnknown

  VersionConstraint = tuple
    op:      string
    version: Version

  PurlPattern* = object
    raw*:        string # as configured
    name:        string # `type/namespace/name` glob, see `purlParts`
    versionGlob: string # empty: any version
    constraints: seq[VersionConstraint]

proc purlType*(purl: string): string =
  ## lowercase type of `pkg:<type>/...`, empty when `purl` is not a purl
  if not purl.toLowerAscii().startsWith("pkg:"):
    return ""
  let rest = purl[4 .. ^1].strip(leading = true, trailing = false, chars = {'/'})
  let slash = rest.find('/')
  if slash <= 0:
    return ""
  return rest[0 ..< slash].toLowerAscii()

proc normalizePypiName(name: string): string =
  # https://packaging.python.org/en/latest/specifications/name-normalization/
  var lastSep = false
  for c in name:
    if c in {'-', '_', '.'}:
      if not lastSep:
        result.add('-')
      lastSep = true
    else:
      result.add(c)
      lastSep = false

proc qualifierString(value: string): bool =
  # In a pattern, '?' is a wildcard unless it begins purl qualifiers.
  # Keys use the purl ASCII key alphabet; values must be nonempty.
  if value == "":
    return false
  for entry in value.split('&'):
    let equals = entry.find('=')
    if equals <= 0 or equals == entry.high:
      return false
    for c in entry[0 ..< equals]:
      if c notin Letters + Digits + {'_', '.', '-'}:
        return false
  true

proc purlParts*(purl: string, pattern = false): tuple[name, version: string] =
  ## `pkg:type/namespace/name@version?qualifiers#subpath` as a lowercase,
  ## percent-decoded `type/namespace/name` and the decoded version. With
  ## `pattern`, a `?` only starts qualifiers when `key=value` pairs follow,
  ## as it is a glob wildcard otherwise.
  var s = purl.strip()
  if s.toLowerAscii().startsWith("pkg:"):
    s = s[4 .. ^1]
  s = s.strip(trailing = false, chars = {'/'})
  let hash = s.find('#')
  if hash >= 0:
    s = s[0 ..< hash]
  let query = if pattern: s.rfind('?') else: s.find('?')
  if query >= 0 and (not pattern or qualifierString(s[query + 1 .. ^1])):
    s = s[0 ..< query]
  # the version follows the last `@` that does not start a path segment, so
  # npm scopes written unencoded (`pkg:npm/@angular/core`) are not versions
  var at = -1
  for i in countdown(len(s) - 1, 1):
    if s[i] == '@' and s[i - 1] != '/':
      at = i
      break
  var name = if at >= 0: s[0 ..< at] else: s
  if at >= 0:
    result.version = decodeUrl(s[at + 1 .. ^1], decodePlus = false)
  name = decodeUrl(name, decodePlus = false).toLowerAscii()
  let slash = name.find('/')
  if slash > 0 and name[0 ..< slash] == "pypi":
    let last = name.rfind('/')
    name = name[0 .. last] & normalizePypiName(name[last + 1 .. ^1])
  result.name = name

proc normalizeVersion(version: string): string =
  # go module versions carry a `v` prefix other ecosystems do not
  result = version.toLowerAscii()
  if len(result) > 1 and result[0] == 'v' and result[1] in Digits:
    result = result[1 .. ^1]

proc parsePurlPattern*(value: string): PurlPattern =
  ## Raises `ValueError` for a pattern that is not a purl or has an invalid
  ## version range.
  if not value.strip().toLowerAscii().startsWith("pkg:"):
    raise newException(ValueError, "must start with pkg:")
  let (name, version) = value.purlParts(pattern = true)
  if '/' notin name or name.startsWith("/") or name.endsWith("/"):
    raise newException(ValueError, "must be pkg:<type>/<name>")
  result = PurlPattern(raw: value, name: name)
  let spec = version.strip()
  if spec == "" or spec[0] notin {'<', '>', '=', '!'}:
    result.versionGlob = spec
    return
  for part in spec.split(','):
    let constraint = part.strip()
    var i = 0
    while i < len(constraint) and constraint[i] in {'<', '>', '=', '!'}:
      inc(i)
    var op = constraint[0 ..< i]
    if op == "==":
      op = "="
    if op notin ["<", "<=", ">", ">=", "=", "!="]:
      raise newException(ValueError, "invalid version operator " & escapeJson(op))
    try:
      result.constraints.add((op, parseVersion(constraint[i .. ^1].strip())))
    except CatchableError:
      raise newException(ValueError, "invalid version " & escapeJson(constraint[i .. ^1]) &
                                     " (ranges support MAJOR[.MINOR[.PATCH]][-suffix])")

proc satisfies(version: Version, constraint: VersionConstraint): bool =
  case constraint.op
  of "<":  version < constraint.version
  of "<=": version <= constraint.version
  of ">":  version > constraint.version
  of ">=": version >= constraint.version
  of "!=": version != constraint.version
  else:    version == constraint.version

proc matches*(pattern: PurlPattern, purl: string): tuple[result: PurlMatch, reason: string] =
  ## `pmUnknown`, with the reason, when the name matches but the version
  ## cannot be compared with the pattern's range (missing or not semver-like)
  if purl == "":
    return (pmNoMatch, "")
  let (name, version) = purl.purlParts()
  if not globMatch(pattern.name, name):
    return (pmNoMatch, "")
  if len(pattern.constraints) == 0:
    if pattern.versionGlob == "" or
       globMatch(pattern.versionGlob.normalizeVersion(), version.normalizeVersion()):
      return (pmMatch, "")
    return (pmNoMatch, "")
  var parsed: Version
  try:
    parsed = parseVersion(version)
  except CatchableError:
    return (pmUnknown, "version " & escapeJson(version) & " cannot be compared with " &
                       pattern.raw)
  for constraint in pattern.constraints:
    if not parsed.satisfies(constraint):
      return (pmNoMatch, "")
  return (pmMatch, "")

proc firstMatch*(patterns: openArray[PurlPattern], purl: string): tuple[result: PurlMatch, reason: string] =
  ## `pmMatch` with the matching pattern's `raw` as reason, else `pmUnknown`
  ## with the reason of the last pattern that could not decide, else
  ## `pmNoMatch`
  result = (pmNoMatch, "")
  for pattern in patterns:
    let (res, reason) = pattern.matches(purl)
    case res
    of pmMatch:
      return (pmMatch, pattern.raw)
    of pmUnknown:
      result = (pmUnknown, reason)
    of pmNoMatch:
      discard
