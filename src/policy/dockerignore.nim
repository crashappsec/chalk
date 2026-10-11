##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `.dockerignore` handling for policy rules that report files of a build
## context: what docker leaves out of the context is not part of the build.
## Matching is moby-compatible (see docker/tar.nim).
## https://docs.docker.com/build/concepts/context/#dockerignore-files

import std/[
  os,
  strutils,
]
import ".."/[
  types,
]
from ".."/docker/tar import isExcluded, isValidPattern, hasNegationForDir
import ./api

type
  DockerIgnore* = object
    path*:     string      # the ignore file read, empty when there is none
    patterns*: seq[string] # valid patterns, in order, leading `/` removed
    invalid*:  seq[string] # lines skipped as invalid patterns

proc dockerignorePath*(dir: string, dockerfilePath = ""): string =
  ## The ignore file docker applies to context `dir`:
  ## `<Dockerfile>.dockerignore` when it exists, else `<dir>/.dockerignore`,
  ## else empty. Pass `dockerfilePath` only for the main context, as BuildKit
  ## applies the Dockerfile's ignore file to it alone.
  if dockerfilePath != "":
    let specific = dockerfilePath & ".dockerignore"
    if fileExists(specific):
      return specific
  let root = dir / ".dockerignore"
  if fileExists(root):
    return root
  return ""

proc cleanPattern(pattern: string): string =
  ## Lexical cleanup as moby's ignorefile.ReadAll does with `filepath.Clean`
  ## (`./a` -> `a`, `a//b` -> `a/b`, `a/../b` -> `b`), keeping a trailing `/`
  ## as it only signals a directory. The leading `/` moby strips afterwards is
  ## dropped too; `..` above it is dropped as `filepath.Clean` does.
  ## https://github.com/moby/patternmatcher/blob/main/ignorefile/ignorefile.go
  let rooted = pattern.startsWith('/')
  var parts: seq[string]
  for part in pattern.split('/'):
    case part
    of "", ".":
      discard
    of "..":
      if len(parts) > 0 and parts[^1] != "..":
        discard parts.pop()
      elif not rooted:
        parts.add(part)
    else:
      parts.add(part)
  result = parts.join("/")
  if result != "" and pattern.endsWith('/'):
    result &= "/"

proc parseDockerignore*(content: string, path = ""): DockerIgnore =
  result.path = path
  for line in content.splitLines():
    let p = line.strip()
    if p.len == 0 or p.startsWith('#'):
      continue
    let negate = p.startsWith('!')
    let pattern = (if negate: p[1 .. ^1] else: p).strip().cleanPattern()
    # docker fails the build on these; skipping keeps more files checked
    if not isValidPattern(pattern):
      result.invalid.add(p)
      continue
    result.patterns.add((if negate: "!" else: "") & pattern)

proc loadDockerignore*(dir: string, dockerfilePath = ""): DockerIgnore =
  ## The patterns of `dockerignorePath(dir, dockerfilePath)`; none when there
  ## is no ignore file. Raises `IOError` when it cannot be read.
  let path = dir.dockerignorePath(dockerfilePath)
  if path == "":
    return
  result = parseDockerignore(readFile(path), path)
  for p in result.invalid:
    warn("policy: ignoring invalid pattern in " & path & ": " & p)

proc isIgnored*(ignore: DockerIgnore, relPath: string): bool =
  ## whether docker leaves `relPath`, relative to the context, out of it
  relPath != "" and relPath.isExcluded(ignore.patterns)

proc prunes*(ignore: DockerIgnore, relDir: string): bool =
  ## whether a walk of the context can skip directory `relDir` entirely:
  ## it is ignored and no negation pattern can re-include anything below it
  ignore.isIgnored(relDir) and not relDir.hasNegationForDir(ignore.patterns)

proc mainContextDockerfile*(input: PolicyInput, dir: string): string =
  ## `input.dockerfilePath` when `dir` is the main build context, for
  ## `loadDockerignore`; empty for named contexts
  if input.mainContextDir != "" and dir == input.mainContextDir:
    return input.dockerfilePath
  return ""
