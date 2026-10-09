##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Small helpers shared by policy rules that report findings about files of
## the build context.

import std/[
  algorithm,
  options,
  os,
  strutils,
]
import ./api

export options

proc isWithin*(path, dir: string): bool =
  ## whether absolute `path` is `dir` or below it
  let dir = dir.strip(leading = false, chars = {'/'})
  path == dir or dir == "" or path.startsWith(dir & "/")

proc contextPath*(path, root, dir: string): Option[string] =
  ## `path`, relative to `root` the way tools report what they scanned (syft
  ## writes a leading `/`), as a path relative to context directory `dir`;
  ## `none` when it is outside `dir`. An empty `root` means `dir`, and `/`
  ## takes absolute paths. Empty paths stay empty.
  if path == "":
    return some(path)
  let base = if root == "": dir else: root
  # joinPath normalizes `..`, so a path cannot escape `dir` with one
  let absolute = base / path.strip(trailing = false, chars = {'/'})
  if not absolute.isWithin(dir):
    return none(string)
  return some(absolute.relativePath(dir))

proc capFindings*(findings: seq[PolicyFinding], rule: string, limit: int,
                  what: string): seq[PolicyFinding] =
  ## Keeps reports and the job summary bounded: the first `limit` findings,
  ## violations first, and one finding counting the rest, e.g.
  ## `12 more packages not listed`. The summary is a violation when a
  ## dropped finding is, so the policy result does not change.
  if len(findings) <= limit:
    return findings
  let sorted = findings.sorted(proc(a, b: PolicyFinding): int =
    cmp(a.kind != "violation", b.kind != "violation"))
  result = sorted[0 ..< limit]
  var violations = 0
  for f in sorted[limit .. ^1]:
    if f.kind == "violation":
      inc(violations)
  result.add(newSubjectFinding(rule,
                               (if violations > 0: "violation" else: "error"),
                               rule,
                               $(len(sorted) - limit) & " more " & what & " not listed"))
