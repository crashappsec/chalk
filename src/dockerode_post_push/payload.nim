##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

const dockerPostPushMaxPayloadBytes* = 64 * 1024

proc readDockerPostPushPayload*(input: File): string =
  ## Read at most one byte beyond the accepted limit so callers can reject it.
  result = newString(dockerPostPushMaxPayloadBytes + 1)
  var offset = 0
  while offset < result.len:
    let count = input.readChars(result, offset, result.len - offset)
    if count == 0:
      break
    offset += count
  result.setLen(offset)
