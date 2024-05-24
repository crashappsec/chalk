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
import "."/[exe, ids]

proc inspectHistoryCommands*(name: string): seq[string] =
  ## utility function for getting docker image history
  trace("docker: getting history for " & name)
  let
    args   = @["history", name, "--format", "{{.CreatedBy}}", "--no-trunc"]
    output = runDockerGetEverything(args)
    stdout = output.getStdOut().strip()
    stderr = output.getStdErr().strip()
  if output.getExit() != 0:
    raise newException(
      ValueError,
      "cannot get history for " & name & " due to: " &
      stdout & " " & stderr,
    )
  result = stdout.splitLines()
  if len(result) == 0:
    raise newException(
      ValueError,
      "image has no layers in its history " & name &
      "\n" & stdout & " " & stderr
    )

proc inspectJson(name: string, what: string): JsonNode =
  ## utility function for getting docker inspect json
  trace("docker: inspecting " & what & " " & name)
  var
    args   = @[what, "inspect", name]
  if supportsInspectJsonFlag():
    args &= @["--format", "json"]
  let
    output = runDockerGetEverything(args)
    stdout = output.getStdOut().strip()
    stderr = output.getStdErr().strip()
  if output.getExit() != 0:
    raise newException(
      ValueError,
      "cannot inspect " & what & " " & name & " due to: " &
      stdout & " " & stderr,
    )
  let json = parseJson(stdout)
  if len(json) != 1:
    raise newException(
      ValueError,
      "" & what & " " & name & " was not found to be inspected.",
    )
  result = json[0]

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

proc inspectImageJson*(name: string, platform = DockerPlatform(nil)): JsonNode =
  ## fetch image json from local docker daemon (if present)
  let
    data          = inspectJson(name, "image")
    os            = data{"Os"}.getStr()
    arch          = data{"Architecture"}.getStr()
    variant       = data{"Variant"}.getStr()
    foundPlatform = DockerPlatform(os: os, architecture: arch, variant: variant)
  if platform != nil and platform != foundPlatform:
    raise newException(
      ValueError,
      "docker: local image " & name & " doesn't match targeted platform: " &
      $foundPlatform & " != " & $platform,
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
      yield line

iterator allImageIDs*(): string =
  for id in allIDs("images", "images"):
    yield id

iterator allContainerIDs*(): string =
  for id in allIDs("containers", "ps"):
    yield id
