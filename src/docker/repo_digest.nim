##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ./ids

proc repoDigestMatches*(image, expectedDigest: string,
                        repoDigests: seq[string]): bool =
  let
    expected         = parseImage(image)
    expectedHash     = expectedDigest.extractDockerHash()
    expectedRegistry = expected.registry
    expectedName     = expected.name
  for value in repoDigests:
    let candidate = parseImage(value)
    if candidate.registry == expectedRegistry and
       candidate.name == expectedName and
       candidate.digest == expectedHash:
      return true
  return false
