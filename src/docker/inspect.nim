##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## module for inspecting local docker resources such as images/containers
##
## inspect - return raw json as provided by docker CLI without any chalk context

import std/[json]
import ".."/[config]
import "."/[exe, hash]

proc inspectJson(name: string, what: string): JsonNode =
  ## utility function for getting docker inspect json
  trace("docker: inspecting " & what & " " & name)
  let
    args   = @[what, "inspect", name, "--format", "json"]
    output = runDockerGetEverything(args)
    stdout = output.getStdOut().strip()
    stderr = output.getStdErr().strip()
  if output.getExit() != 0:
    raise newException(
      ValueError,
      "docker: cannot inspect " & what & " " & name & " due to: " &
      stdout & " " & stderr,
    )
  let json = parseJson(stdout)
  if len(json) != 1:
    raise newException(
      ValueError,
      "docker: " & what & " " & name & " was not found to be inspected.",
    )
  return json[0]

proc exists(name: string, what: string): bool =
  try:
    discard inspectJson(name, what)
    return true
  except:
    return false

proc dockerImageExists*(name: string): bool =
  return exists(name, "image")

proc dockerContainerExists*(name: string): bool =
  return exists(name, "container")

proc inspectImageJson*(name: string, platform: string = ""): JsonNode =
  ## fetch image json from local docker daemon (if present)
  let
    data     = inspectJson(name, "image")
    os       = data{"Os"}.getStr()
    arch     = data{"Architecture"}.getStr()
    together = os & "/" & arch
  if platform != "" and platform != together:
    raise newException(
      ValueError,
      "docker: local image " & name & " doesn't match targeted platform: " &
      together & " != " & platform,
    )
  return data

proc inspectContainerJson*(name: string): JsonNode =
  ## fetch container json from local docker daemon (if present)
  return inspectJson(name, "container")

iterator allIDs(what: string, cmd: string): string =
  ## utility function for getting all docker ids in local system (container or image)
  let
    output = runDockerGetEverything(@[cmd, "--no-trunc", "--format", "{{.ID}}"])
    stdout = output.getStdOut().strip()
    stderr = output.getStdErr().strip()

  if output.getExit() != 0 or stdout == "":
    error("docker: could not find any " & what & ": " & stdout & " " & stderr)
  else:
    for line in stdout.splitLines():
      yield line.extractDockerHash()

iterator allImageIDs*(): string =
  for id in allIDs("images", "images"):
    yield id

iterator allContainerIDs*(): string =
  for id in allIDs("containers", "ps"):
    yield id
