##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  posix,
]

const dockerPostPushMaxPayloadBytes* = 64 * 1024

proc dockerPostPushHomeDir*(): string =
  ## Match Node's os.homedir(): prefer HOME, then the current user's passwd
  ## entry. Nim's getHomeDir() returns "/" when HOME is absent on POSIX.
  result = getEnv("HOME")
  if result == "":
    let passwd = getpwuid(getuid())
    if passwd != nil and passwd.pw_dir != nil:
      result = $passwd.pw_dir

proc dockerPostPushSocketSupported*(socketPath: string): bool =
  if socketPath == "/var/run/docker.sock":
    return true
  let home = dockerPostPushHomeDir()
  return home != "" and socketPath == home / ".docker/run/docker.sock"

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
