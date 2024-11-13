##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## utilities for interacting with docker images

import ".."/[config, util]
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

proc fetchManifestListForImage*(image: DockerImage, platforms: seq[DockerPlatform]): DockerManifest =
  trace("docker: fetching manifest list for: " & $image & " " & $($platforms))
  try:
    if len(platforms) != 1:
      raise newException(ValueError, "multi-platform build. cannot inspect local image for manifest digest")
    # if image is present locally, honor its digest
    let
      local   = inspectImageJson(image.asRepoRef(), platforms[0])
      digests = parseImages(local{"RepoDigests"}.getStrElems())
    var
      sameRepo     = newSeq[DockerImage]()
      sameRegistry = newSeq[DockerImage]()
      other        = newSeq[DockerImage]()
    for remote in digests:
      # take precedence of locally pulled image for the same repo. e.g:
      # docker pull alpine
      # echo FROM alpine | docker build -f - .
      if remote.repo == image.repo:
        sameRepo.add(remote)
      # attempt all get manifest from renamed refs but in same registry.
      # as it is the same registry having same digest is much more likely
      # e.g:
      # docker pull alpine
      # docker tag alpine foo
      # echo FROM foo | docker build -f - .
      elif remote.registry == image.registry:
        sameRegistry.add(remote)
      # finally try all other registries
      else:
        other.add(remote)
    for remote in sameRepo & sameRegistry & other:
      try:
        return fetchListOrImageManifest(remote, platforms)
      except:
        trace("docker: " & getCurrentExceptionMsg())
    raise newException(ValueError, "Could not find manifest list for " & $image)
  except:
    trace("docker: " & getCurrentExceptionMsg())
    return fetchListManifest(image, platforms)

proc fetchImageOrManifestConfig(image: DockerImage, platform: DockerPlatform): JsonNode =
  trace("docker: fetching config for: " & $image & " " & $platform)
  try:
    return inspectImageJson(image.asRepoRef(), platform){"Config"}
  except:
    if hasBuildX():
      return fetchImageManifest(image, platform).config.json{"config"}
    else:
      trace("docker: buildx is missing. pulling image locally for inspection: " & getCurrentExceptionMsg())
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
