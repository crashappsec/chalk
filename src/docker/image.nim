##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## utilities for interacting with docker images

import ".."/[config]
import "."/[exe, ids, inspect, manifest, dockerfile]

proc pullImage*(name: string) =
  ## utility function for pull docker image to local daemon
  trace("docker: pulling " & name)
  let
    args   = @["pull", name]
    output = runDockerGetEverything(args)
    stdout = output.getStdOut().strip()
    stderr = output.getStdErr().strip()
  if output.getExit() != 0:
    raise newException(
      ValueError,
      "cannot pull " & name & " due to: " &
      stdout & " " & stderr,
    )

proc fetchImageOrManifestConfig(image: DockerImage, platform: DockerPlatform): JsonNode =
  trace("docker: fetching config for: " & $image & " " & $platform)
  try:
    return inspectImageJson(image.asRepoRef(), platform){"Config"}
  except:
    if hasBuildX():
      return fetchImageManifest(image, platform).config.json{"config"}
    else:
      trace("docker: buildx is missing. pulling image locally for inspection")
      pullImage(image.asRepoRef())
      return inspectImageJson(image.asRepoRef(), platform){"Config"}

proc fetchImageEntrypoint*(image: DockerImage, platform: DockerPlatform): DockerEntrypoint =
  ## fetch image entrypoints (entrypoint/cmd/shell)
  ## fetches from local docker cache (if present),
  ## else will directly query registry
  # scrach image is a special image without any entrypoint config
  if $image == "scratch":
    return (nil, nil, nil)
  let
    imageInfo  = fetchImageOrManifestConfig(image, platform)
    entrypoint = fromJson[EntrypointInfo](imageInfo{"Entrypoint"})
    cmd        = fromJson[CmdInfo](imageInfo{"Cmd"})
    shell      = fromJson[ShellInfo](imageInfo{"Shell"})
  return (entrypoint, cmd, shell)

proc fetchImageUser*(image: DockerImage, platform: DockerPlatform): string =
  ## fetch image user
  ## fetches from local docker cache (if present),
  ## else will directly query registry
  # scratch image is a special image without any users
  if $image == "scratch":
    return ""
  let imageInfo = fetchImageOrManifestConfig(image, platform)
  return imageInfo{"User"}.getStr("")
